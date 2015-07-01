module dseq;

import std.stdio;
import std.algorithm;
import std.math;

import jack.client;
import sndfile.sndfile;
import samplerate.samplerate;

import gtk.MainWindow;
import gtk.Main;
import gtk.Widget;

class AudioError: Exception {
    this(string msg) {
        super(msg);
    }
}

class FileError: Exception {
    this(string msg) {
        super(msg);
    }
}

alias nframes_t = jack_nframes_t;
alias sample_t = jack_default_audio_sample_t;
alias channels_t = uint;

class Region {
public:
    this(nframes_t sampleRate, channels_t nChannels, sample_t[] audioBuffer) {
        _sampleRate = sampleRate;
        _nChannels = nChannels;
        _audioBuffer = audioBuffer;
        _nframes = cast(nframes_t)(audioBuffer.length / nChannels);

        _initCache();
    }

    // create a region from a file, leaving the sample rate unaltered
    static Region fromFile(string fileName) {
        SNDFILE* infile;
        SF_INFO sfinfo;

        // attempt to open the given file
        infile = sf_open(fileName.toStringz(), SFM_READ, &sfinfo);
        if(!infile) {
            throw new FileError("Could not open file: " ~ fileName);
        }

        // close the file when leaving this scope
        scope(exit) sf_close(infile);

        // allocate contiguous audio buffer
        sample_t[] audioBuffer = new sample_t[](cast(size_t)(sfinfo.frames * sfinfo.channels));

        // read the file into the audio buffer
        sf_count_t readcount;
        static if(is(sample_t == float)) {
            readcount = sf_read_float(infile, audioBuffer.ptr, cast(sf_count_t)(audioBuffer.length));
        }
        else if(is(sample_t == double)) {
            readcount = sf_read_double(infile, audioBuffer.ptr, cast(sf_count_t)(audioBuffer.length));
        }
        else {
            static assert(0);
        }

        // throw exception if file failed to read
        if(!readcount) {
            throw new FileError("Could not read file: " ~ fileName);
        }

        return new Region(cast(nframes_t)(sfinfo.samplerate), cast(channels_t)(sfinfo.channels), audioBuffer);
    }

    // create a region from a file, converting to the given sample rate if necessary
    static Region fromFile(string fileName, nframes_t sampleRate) {
        Region region = fromFile(fileName);
        region.convertSampleRate(sampleRate);
        return region;
    }

    // normalize region to the given maximum gain, in dBFS
    void normalize(sample_t maxGain = -0.1) {
        sample_t minSample, maxSample;
        _minMax(minSample, maxSample);
        maxSample = max(abs(minSample), abs(maxSample));

        sample_t sampleFactor =  pow(10, (maxGain > 0 ? 0 : maxGain) / 20) / maxSample;
        foreach(ref s; _audioBuffer) {
            s *= sampleFactor;
        }
    }

    void convertSampleRate(nframes_t newSampleRate, bool normalize = true) {
        if(newSampleRate != _sampleRate && newSampleRate > 0) {
            // constant indicating the algorithm to use for sample rate conversion
            enum converter = SRC_SINC_MEDIUM_QUALITY;

            // allocate audio buffers for input/output
            float[] dataIn = new float[](_audioBuffer.length);
            float[] dataOut;

            // libsamplerate requires floats
            static if(is(sample_t == float)) {
                dataIn = _audioBuffer.dup;
                dataOut = _audioBuffer;
            }
            else if(is(sample_t == double)) {
                foreach(i, sample; dataIn) {
                    sample = _audioBuffer[i];
                }
                dataOut = new float[](_audioBuffer.length);
            }
            else {
                static assert(0);
            }

            // compute the parameters for libsamplerate
            double srcRatio = (1.0 * newSampleRate) / _sampleRate;
            if(!src_is_valid_ratio(srcRatio)) {
                throw new AudioError("Invalid sample rate requested: " ~ to!string(newSampleRate));
            }
            SRC_DATA srcData;
            srcData.data_in = dataIn.ptr;
            srcData.data_out = dataOut.ptr;
            srcData.input_frames = cast(long)(_nframes);
            srcData.output_frames = cast(long)(ceil(nframes * srcRatio));
            srcData.src_ratio = srcRatio;

            // compute the sample rate conversion
            int error = src_simple(&srcData, converter, cast(int)(_nChannels));
            if(error) {
                throw new AudioError("Sample rate conversion failed: " ~ to!string(src_strerror(error)));
            }
            dataOut.length = cast(size_t)(srcData.output_frames_gen);

            // convert the float buffer back to sample_t if necessary
            static if(is(sample_t == double)) {
                _audioBuffer.length = dataOut.length;
                foreach(i, sample; dataOut) {
                    _audioBuffer[i] = sample;
                }
            }

            // normalize, if requested
            if(normalize) {
                this.normalize();
            }
        }
    }

    const(sample_t) opIndex(nframes_t frame, channels_t channelIndex) const {
        return frame >= offset ?
            (frame < _offset + _nframes ? _audioBuffer[(frame - _offset) * _nChannels + channelIndex] : 0 ) : 0;
    }

    @property const(sample_t[]) audioBuffer() const { return _audioBuffer; }
    @property const(nframes_t) sampleRate() const { return _sampleRate; }
    @property const(channels_t) nChannels() const { return _nChannels; }
    @property const(nframes_t) nframes() const { return _nframes; }
    @property const(nframes_t) offset() const { return _offset; }

private:
    static void _minMax(out sample_t minSample, out sample_t maxSample, const(sample_t[]) sourceData) {
        minSample = 1;
        maxSample = -1;
        foreach(s; sourceData) {
            if(s > maxSample) maxSample = s;
            if(s < minSample) minSample = s;
        }
    }
    void _minMax(out sample_t minSample, out sample_t maxSample) const {
        _minMax(minSample, maxSample, _audioBuffer);
    }

    static void _minMaxChannel(channels_t channelIndex,
                               channels_t nChannels,
                               out sample_t minSample,
                               out sample_t maxSample,
                               const(sample_t[]) sourceData) {
        minSample = 1;
        maxSample = -1;
        for(size_t i = channelIndex; i < sourceData.length; i += nChannels) {
            if(sourceData[i] > maxSample) maxSample = sourceData[i];
            if(sourceData[i] < minSample) minSample = sourceData[i];
        }
    }
    void _minMaxChannel(channels_t channelIndex,
                        out sample_t minSample,
                        out sample_t maxSample) const {
        _minMaxChannel(channelIndex, _nChannels, minSample, maxSample, _audioBuffer);
    }

    void _initCache() {
        immutable(nframes_t[]) cacheSampleSizes = [ 10, 100, 1000, 10000 ];
        static assert(cacheSampleSizes.length > 0);
        _waveformCacheList = null;

        for(channels_t c = 0; c < _nChannels; ++c) {
            WaveformCache[] channelCache;
            channelCache ~= new WaveformCache(cacheSampleSizes[0], c, _nChannels, _audioBuffer);
            foreach(sampleSize; cacheSampleSizes[1 .. $]) {
                channelCache ~= new WaveformCache(sampleSize,
                                                  channelCache[$ - 1].minValues,
                                                  channelCache[$ - 1].maxValues);
            }
            _waveformCacheList ~= channelCache;
        }
    }

    static class WaveformCache {
    public:
        this(nframes_t sampleSize, channels_t channelIndex, channels_t nChannels, const(sample_t[]) audioData) {
            assert(sampleSize > 0);

            _sampleSize = sampleSize;
            _length = (audioData.length / nChannels) / sampleSize;
            _minValues = new sample_t[](_length);
            _maxValues = new sample_t[](_length);

            for(size_t i = 0, j = 0; i < audioData.length && j < _length; i += sampleSize * nChannels, ++j) {
                _minMaxChannel(channelIndex,
                               nChannels,
                               _minValues[j],
                               _maxValues[j],
                               audioData[i .. i + sampleSize * nChannels]);
            }
        }

        this(nframes_t sampleSize, const(sample_t[]) srcMinValues, const(sample_t[]) srcMaxValues) {
            assert(sampleSize > 0);
            assert(srcMinValues.length == srcMaxValues.length);

            _sampleSize = sampleSize;
            _minValues = new sample_t[](srcMinValues.length / sampleSize);
            _maxValues = new sample_t[](srcMaxValues.length / sampleSize);

            immutable(size_t) srcCount = min(srcMinValues.length, srcMaxValues.length);
            immutable(size_t) destCount = srcCount / sampleSize;
            for(size_t i = 0, j = 0; i < srcCount && j < destCount; i += sampleSize, ++j) {
                immutable(size_t) sampleCount = i + sampleSize < srcCount ? sampleSize : srcCount - i;
                for(size_t k = 0; k < sampleCount; ++k) {
                    _minValues[j] = 1;
                    _maxValues[j] = -1;
                    if(srcMinValues[i + k] < _minValues[j]) {
                        _minValues[j] = srcMinValues[i + k];
                    }
                    if(srcMaxValues[i + k] > _maxValues[j]) {
                        _maxValues[j] = srcMaxValues[i + k];
                    }
                }
            }
        }

        @property const(nframes_t) sampleSize() const { return _sampleSize; }
        @property size_t length() const { return _length; }
        @property const(sample_t[]) minValues() const { return _minValues; }
        @property const(sample_t[]) maxValues() const { return _maxValues; }

    private:
        nframes_t _sampleSize;
        size_t _length;
        sample_t[] _minValues;
        sample_t[] _maxValues;
    }

    WaveformCache[][] _waveformCacheList; // indexed as [channel, waveform]

    nframes_t _sampleRate; // sample rate of the audio data
    channels_t _nChannels; // number of channels in the audio data
    sample_t[] _audioBuffer; // raw audio data for all channels
    nframes_t _nframes; // number of frames in the audio data, where 1 frame contains 1 sample for each channel

    nframes_t _offset; // the offset, in frames, for the start of this region
}

class Track {
public:
    void addRegion(Region region) {
        _regions ~= region;
        _resizeIfNecessary(region.offset + region.nframes);
    }

package:
    this(bool delegate(nframes_t) resizeIfNecessary) {
        _resizeIfNecessary = resizeIfNecessary;
    }
    
    void mixStereo(nframes_t offset, nframes_t bufNFrames, sample_t* mixBuf1, sample_t* mixBuf2) const {
        for(nframes_t i = 0; i < bufNFrames; ++i) {
            foreach(r; _regions) {
                mixBuf1[i] += r[offset + i, 0];
                mixBuf2[i] += r[offset + i, 1];
            }
        }
    }

private:
    Region[] _regions;
    bool delegate(nframes_t) _resizeIfNecessary;
}

class Mixer {
public:
    this(string appName) {
        try {
            _openJack(appName);
        }
        catch(JackError e) {
            throw new AudioError(e.msg);
        }
    }
    ~this() {
        _closeJack();
    }

    Track createTrack() {
        Track track = new Track(&resizeIfNecessary);
        _tracks ~= track;
        return track;
    }

    bool resizeIfNecessary(nframes_t newNFrames) {
        if(newNFrames > _nframes) {
            _nframes = newNFrames;
            return true;
        }
        return false;
    }

    @property nframes_t sampleRate() { return _client.get_sample_rate(); }

    @property const(nframes_t) nframes() const { return _nframes; }
    @property nframes_t nframes(nframes_t newNFrames) { return (_nframes = newNFrames); }

    @property const(nframes_t) offset() const { return _offset; }
    @property nframes_t offset(nframes_t newOffset) { return (_offset = newOffset); }

    @property bool playing() const { return _playing; }
    void play() { _playing = true; }
    void pause() { _playing = false; }
    
private:
    void _openJack(string appName) {
        _client = new JackClient;
        _client.open(appName, JackOptions.JackNoStartServer, null);

        JackPort mixOut1 = _client.register_port("Mix1", JACK_DEFAULT_AUDIO_TYPE, JackPortFlags.JackPortIsOutput, 0);
        JackPort mixOut2 = _client.register_port("Mix2", JACK_DEFAULT_AUDIO_TYPE, JackPortFlags.JackPortIsOutput, 0);

        // callback to process a single period of audio data
        _client.process_callback = delegate int(jack_nframes_t bufNFrames) {
            float* mixBuf1 = mixOut1.get_audio_buffer(bufNFrames);
            float* mixBuf2 = mixOut2.get_audio_buffer(bufNFrames);

            // initialize the buffers to silence
            import core.stdc.string: memset;
            memset(mixBuf1, 0, jack_nframes_t.sizeof * bufNFrames);
            memset(mixBuf2, 0, jack_nframes_t.sizeof * bufNFrames);

            if(_playing && _offset >= _nframes) {
                _playing = false;
                _offset = _nframes;
            }
            else if(_playing) {
                foreach(t; _tracks) {
                    t.mixStereo(_offset, bufNFrames, mixBuf1, mixBuf2);
                }

                _offset += bufNFrames;
            }

            return 0;
        };

        _client.activate();

        // attempt to connect to physical playback ports
        string[] playbackPorts =
            _client.get_ports("", "", JackPortFlags.JackPortIsInput | JackPortFlags.JackPortIsPhysical);
        if(playbackPorts.length >= 2) {
            _client.connect(mixOut1.get_name(), playbackPorts[0]);
            _client.connect(mixOut2.get_name(), playbackPorts[1]);
        }
    }

    void _closeJack() {
        if(_client) {
            _client.close();
        }
    }

    JackClient _client;
    Track[] _tracks;

    nframes_t _nframes;
    nframes_t _offset;
    bool _playing;
}

void main(string[] args) {
    string appName = "dseq";

    if(!(args.length >= 2)) {
        writeln("Must provide audio file argument!");
        return;
    }

    try {
        Mixer mixer = new Mixer(appName);

        Region testRegion;
        try {
            testRegion = Region.fromFile(args[1], mixer.sampleRate);
        }
        catch(FileError e) {
            writeln("Fatal file error: ", e.msg);
        }

        Track track = mixer.createTrack();
        track.addRegion(testRegion);
        mixer.play();
    }
    catch(AudioError e) {
        writeln("Fatal audio error: ", e.msg);
    }

    Main.init(args);
    MainWindow win = new MainWindow(appName);
    win.showAll();
    Main.run();
}
