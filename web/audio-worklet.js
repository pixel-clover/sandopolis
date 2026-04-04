// AudioWorklet processor for Sandopolis emulator audio.
// Receives i16 stereo PCM samples from the main thread and plays them back.
// Compatible with Chrome, Firefox, and Safari.

class SandopolisAudioProcessor extends AudioWorkletProcessor {
    constructor() {
        super();
        // Ring buffer: 32K stereo float frames (~0.67s at 48kHz)
        this.bufferSize = 32768 * 2;
        this.buffer = new Float32Array(this.bufferSize);
        this.readPos = 0;
        this.writePos = 0;
        this.count = 0;

        this.port.onmessage = (e) => {
            const samples = e.data; // Int16Array, stereo interleaved
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
        // Handle both stereo (2 channels) and mono (1 channel) output configs.
        const outL = output[0];
        if (!outL) return true;
        const outR = output.length > 1 ? output[1] : null;
        const frames = outL.length;

        for (let i = 0; i < frames; i++) {
            if (this.count >= 2) {
                const l = this.buffer[this.readPos];
                this.readPos = (this.readPos + 1) % this.bufferSize;
                const r = this.buffer[this.readPos];
                this.readPos = (this.readPos + 1) % this.bufferSize;
                this.count -= 2;
                outL[i] = l;
                if (outR) outR[i] = r; else outL[i] = (l + r) * 0.5;
            } else {
                outL[i] = 0;
                if (outR) outR[i] = 0;
            }
        }
        return true;
    }
}

registerProcessor("sandopolis-audio", SandopolisAudioProcessor);
