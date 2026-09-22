import assert from "node:assert/strict";

let Processor;
globalThis.sampleRate = 48000;
globalThis.AudioWorkletProcessor = class {
    constructor() {
        this.port = {postMessage() {}};
    }
};
globalThis.registerProcessor = (_name, implementation) => {
    Processor = implementation;
};

await import("./audio-worklet.js");

const processor = new Processor({processorOptions: {srcRate: 48000}});
const output = [[new Float32Array(128), new Float32Array(128)]];

processor.port.onmessage({data: new Int16Array(2048).fill(16384)});
processor.process([], output);
assert.equal(output[0][0].some((sample) => sample !== 0), false, "audio waits for a stable prebuffer");
assert.equal(processor.count, 2048, "prebuffer is not consumed while waiting");

processor.port.onmessage({data: new Int16Array(2048).fill(16384)});
processor.process([], output);
assert.equal(output[0][0].some((sample) => sample !== 0), true, "audio starts after the prebuffer fills");
assert.ok(processor.count < 4096, "playing consumes buffered samples");

processor.count = 2;
processor.process([], output);
processor.port.onmessage({data: new Int16Array(2048).fill(16384)});
processor.process([], output);
assert.equal(output[0][0].some((sample) => sample !== 0), false, "an underrun re-enters prebuffering");
