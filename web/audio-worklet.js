// AudioWorklet processor for Sandopolis emulator audio.
// Receives i16 stereo PCM samples from the main thread and plays them back.

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
                if (this.count >= this.bufferSize) break; // Drop if full
                this.buffer[this.writePos] = samples[i] / 32768.0;
                this.writePos = (this.writePos + 1) % this.bufferSize;
                this.count++;
            }
        };
    }

    process(inputs, outputs) {
        const outL = outputs[0][0];
        const outR = outputs[0][1];
        if (!outL || !outR) return true;

        const frames = outL.length; // Usually 128
        for (let i = 0; i < frames; i++) {
            if (this.count >= 2) {
                outL[i] = this.buffer[this.readPos];
                this.readPos = (this.readPos + 1) % this.bufferSize;
                outR[i] = this.buffer[this.readPos];
                this.readPos = (this.readPos + 1) % this.bufferSize;
                this.count -= 2;
            } else {
                outL[i] = 0;
                outR[i] = 0;
            }
        }
        return true;
    }
}

registerProcessor("sandopolis-audio", SandopolisAudioProcessor);
