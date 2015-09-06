/// Set of generic classes for giving user feedback on computation progress

module util.progress;

public import std.concurrency;
public import std.parallelism;
private import std.traits;
private import std.typetuple;

private import core.time;

/// A description for a "progress stage".
/// If an operation consists of \a n discrete computations,
/// there should be \n instances of this structure passed to ProgressState as template arguments.
struct StageDesc {
    string name; /// The symbol used for accessing a member stage from a ProgressState instance
    string description; /// A human-readable description the stage's operation (should be a short verb)
}

/// Trait to enforce constraints for the ProgressState template
template isStageDesc(alias T) {
    enum isStageDesc = __traits(isSame, StageDesc, typeof(T));
}

/// A structure describing the current state of a computation with \a n discrete stages.
/// Every stage (i.e., instance of StageDesc) should be passed to this structure as a template argument.
/// Every instance of this class includes a default "complete" stage.
struct ProgressState(Stages...) if(allSatisfy!(isStageDesc, Stages)) {
public:
    mixin("enum Stage : int { " ~ _enumString(Stages) ~ " complete }");
    alias Stage this;
    enum nStages = (EnumMembers!Stage).length - 1;
    static immutable string[nStages] stageDescriptions = mixin(_createStageDescList(Stages));

    /// Constant denoting the number of discrete steps per stage of a computation
    /// Each step will send an update message via a callback, so this should be a relatively low number
    /// to avoid unnecessary overhead
    enum stepsPerStage = 5;

    /// The callback type for progress updates for a given stage
    /// stageFraction specifies the current stage of the computation
    /// Params:
    /// stage = The current stage of the computation
    /// stageFraction = A fraction between `0.0` and `1.0` denoting the completion percentage of the current stage
    /// \Returns `false` if the operation was cancelled; otherwise, `true`
    alias Callback = bool delegate(Stage stage, double stageFraction);

    /// Constructor specifying an initial stage and completion percentage for the entire computation
    this(Stage stage, double stageFraction) {
        this.stage = stage;
        completionFraction = (stage == complete) ? 1.0 : (stage + stageFraction) / nStages;
    }

    /// The current stage of the computation
    Stage stage;

    /// A fraction between `0.0` and `1.0` denoting the completion percentage of the entire computation.
    /// This includes all stages.
    double completionFraction;

private:
    static string _enumString(T...)(T stageDescList) {
        string result;
        foreach(stageDesc; stageDescList) {
            result ~= stageDesc.name ~ ", ";
        }
        return result;
    }

    static string _createStageDescList(T...)(T stageDescList) {
        string result = "[ ";
        foreach(stageDesc; stageDescList) {
            result ~= "\"" ~ stageDesc.description ~ "\", ";
        }
        result ~= " ]";
        return result;
    }
}

/// An abstraction on top of `std.parallelism.Task`
template ProgressTask(Task)
    if(is(Task == U delegate(), U) ||
       (isPointer!Task && __traits(isSame, TemplateOf!(PointerTarget!Task), std.parallelism.Task)) ||
       __traits(isSame, TemplateOf!Task, std.parallelism.Task)) {
    struct ProgressTask {
        string name;

        static if(is(Task == U delegate(), U)) {
            this(string name, Task task) {
                this.name = name;
                this.task = std.parallelism.task!Task(task);
            }

            typeof(std.parallelism.task!Task(delegate U() {})) task;
        }
        else {
            this(string name, Task task) {
                this.name = name;
                this.task = task;
            }

            Task task;
        }
    }
}

alias DefaultProgressTask = ProgressTask!(void delegate());

auto progressTask(Task)(string name, Task task) {
    return ProgressTask!Task(name, task);
}

struct ProgressTaskCallback(ProgressState) if(__traits(isSame, TemplateOf!ProgressState, .ProgressState)) {
    this(Tid callbackTid) {
        this.callbackTid = callbackTid;
    }

    @disable this();

    @property ProgressState.Callback callback() {
        return delegate(ProgressState.Stage stage, double stageFraction) {
            if(!registeredThread) {
                register(ProgressState.mangleof, thisTid);
            }

            send(callbackTid, ProgressState(stage, stageFraction));

            if(!cancelled) {
                receiveTimeout(0.msecs, (bool cancel) { cancelled = cancel; });
            }
            return !cancelled;
        };
    }
    alias callback this;

    Tid callbackTid;
    bool registeredThread;
    bool cancelled;
}