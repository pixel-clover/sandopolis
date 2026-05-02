// AudioWorklet processor for Sandopolis emulator audio.
// Receives i16 stereo PCM samples from the main thread and plays them back.
// Resamples linearly when the source rate (passed via processorOptions.srcRate)
// differs from the AudioContext's output rate so audio plays at correct
// pitch/tempo on devices that force a non-48kHz context (some Bluetooth output).
// Compatible with Chrome, Firefox, and Safari.

class SandopolisAudioProcessor extends AudioWorkletProcessor {
    constructor(options) {
        super();
        // Ring buffer of interleaved stereo samples (L, R, L, R, ...).
        this.bufferSize = 32768 * 2;
        this.buffer = new Float32Array(this.bufferSize);
        // readPos is a fractional FRAME index (one frame = 2 interleaved samples).
        this.readPos = 0;
        this.writePos = 0;
        this.count = 0;
        this.fadeGain = 1.0;
        this.underrunFrames = 0;

        const opts = (options && options.processorOptions) || {};
        const srcRate = opts.srcRate && opts.srcRate > 0 ? opts.srcRate : sampleRate;
        // Fractional input frames advanced per output frame.
        this.step = srcRate / sampleRate;

        this.port.onmessage = (e) => {
            if (e.data === "query-level") {
                this.port.postMessage({type: "level", count: this.count, capacity: this.bufferSize});
                return;
            }
            const samples = e.data;
            const len = samples.length;
            for (let i = 0; i < len; i++) {
                if (this.count >= this.bufferSize) break;
                this.buffer[this.writePos] = samples[i] / 32768.0;
                this.writePos = (this.writePos + 1) % this.bufferSize;
                this.count++;
            }
        };
    }

    process(_inputs, outputs) {
        const output = outputs[0];
        const outL = output[0];
        if (!outL) return true;
        const outR = output.length > 1 ? output[1] : null;
        const frames = outL.length;
        const bufFrames = this.bufferSize / 2;
        const step = this.step;

        for (let i = 0; i < frames; i++) {
            // Need two source frames (4 interleaved samples) ahead for linear interp.
            if (this.count >= 4) {
                const intFrame = Math.floor(this.readPos);
                const frac = this.readPos - intFrame;
                const idx0 = (intFrame * 2) % this.bufferSize;
                const idx1Frame = (intFrame + 1) % bufFrames;
                const idx1 = idx1Frame * 2;
                const l = this.buffer[idx0] * (1 - frac) + this.buffer[idx1] * frac;
                const r = this.buffer[idx0 + 1] * (1 - frac) + this.buffer[idx1 + 1] * frac;

                if (this.fadeGain < 1.0) {
                    this.fadeGain = Math.min(1.0, this.fadeGain + 1.0 / 64.0);
                }
                this.underrunFrames = 0;

                if (outR) {
                    outL[i] = l * this.fadeGain;
                    outR[i] = r * this.fadeGain;
                } else {
                    outL[i] = (l + r) * 0.5 * this.fadeGain;
                }

                this.readPos += step;
                const newInt = Math.floor(this.readPos);
                const consumed = (newInt - intFrame) * 2;
                if (consumed > 0) this.count -= consumed;
                if (this.readPos >= bufFrames) this.readPos -= bufFrames;
            } else {
                if (this.fadeGain > 0.0) {
                    this.fadeGain = Math.max(0.0, this.fadeGain - 1.0 / 32.0);
                }
                outL[i] = 0;
                if (outR) outR[i] = 0;
                this.underrunFrames++;
            }
        }
        return true;
    }
}

registerProcessor("sandopolis-audio", SandopolisAudioProcessor);
