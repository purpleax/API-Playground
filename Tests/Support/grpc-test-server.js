// A small gRPC server for tests and demos, written with nothing but Node's own http2 module.
// It serves demo.Greeter and describes itself through server reflection.
//
//   node grpc-test-server.js [port] [alpha]
//
// With no port (or 0) it picks a free one. It prints "PORT <number>" once it is listening.
// "alpha" makes it offer only the older v1alpha reflection service.

const http2 = require('http2');

// --- A minimal protobuf writer and reader ---

const varint = (value) => {
  let n = BigInt(value);
  if (n < 0n) n += 1n << 64n;
  const out = [];
  while (n >= 0x80n) { out.push(Number(n & 0x7fn) | 0x80); n >>= 7n; }
  out.push(Number(n));
  return Buffer.from(out);
};
const tag = (field, wire) => varint((field << 3) | wire);
const len = (field, buffer) => Buffer.concat([tag(field, 2), varint(buffer.length), buffer]);
const str = (field, text) => len(field, Buffer.from(text));
const num = (field, value) => Buffer.concat([tag(field, 0), varint(value)]);
const msg = (...parts) => Buffer.concat(parts.filter(Boolean));

function read(buffer) {
  const fields = [];
  let i = 0;
  const readVarint = () => {
    let result = 0n, shift = 0n;
    for (;;) { const b = buffer[i++]; result |= BigInt(b & 0x7f) << shift; if (!(b & 0x80)) break; shift += 7n; }
    return result;
  };
  while (i < buffer.length) {
    const key = Number(readVarint());
    const field = key >> 3, wire = key & 7;
    if (wire === 0) fields.push({ field, value: readVarint() });
    else if (wire === 2) { const n = Number(readVarint()); fields.push({ field, value: buffer.subarray(i, i + n) }); i += n; }
    else if (wire === 1) i += 8;
    else if (wire === 5) i += 4;
  }
  return fields;
}

// --- The schema, as FileDescriptorProto bytes ---

const camel = (name) => name.replace(/_(.)/g, (_, c) => c.toUpperCase());
const field = (name, number, type, { label = 1, typeName } = {}) =>
  msg(str(1, name), num(3, number), num(4, label), num(5, type), typeName && str(6, typeName), str(10, camel(name)));
const message = (name, fields, nested = [], options) =>
  msg(str(1, name), ...fields.map((f) => len(2, f)), ...nested.map((n) => len(3, n)), options && len(7, options));
const method = (name, clientStreaming, serverStreaming) =>
  msg(str(1, name), str(2, '.demo.HelloRequest'), str(3, '.demo.HelloReply'), clientStreaming && num(5, 1), serverStreaming && num(6, 1));

const TYPE = { int64: 3, int32: 5, string: 9, message: 11, enum: 14 };

const timestampFile = msg(
  str(1, 'google/protobuf/timestamp.proto'), str(2, 'google.protobuf'),
  len(4, message('Timestamp', [field('seconds', 1, TYPE.int64), field('nanos', 2, TYPE.int32)])),
  str(12, 'proto3'));

const demoFile = msg(
  str(1, 'demo.proto'), str(2, 'demo'), str(3, 'google/protobuf/timestamp.proto'),
  len(4, message('HelloRequest', [field('name', 1, TYPE.string), field('times', 2, TYPE.int32)])),
  len(4, message('HelloReply', [
    field('message', 1, TYPE.string),
    field('count', 2, TYPE.int64),
    field('mood', 3, TYPE.enum, { typeName: '.demo.Mood' }),
    field('tags', 4, TYPE.string, { label: 3 }),
    field('scores', 5, TYPE.message, { label: 3, typeName: '.demo.HelloReply.ScoresEntry' }),
    field('sent_at', 6, TYPE.message, { typeName: '.google.protobuf.Timestamp' }),
  ], [message('ScoresEntry', [field('key', 1, TYPE.string), field('value', 2, TYPE.int32)], [], num(7, 1))])),
  len(5, msg(str(1, 'Mood'), len(2, msg(str(1, 'MOOD_UNKNOWN'), num(2, 0))), len(2, msg(str(1, 'HAPPY'), num(2, 1))))),
  len(6, msg(str(1, 'Greeter'),
    len(2, method('SayHello', false, false)),
    len(2, method('Countdown', false, true)),
    len(2, method('Collect', true, false)),
    len(2, method('Fail', false, false)))),
  str(12, 'proto3'));

const files = { 'demo.proto': demoFile, 'google/protobuf/timestamp.proto': timestampFile };

// --- gRPC framing ---

const frame = (buffer) => { const head = Buffer.alloc(5); head.writeUInt32BE(buffer.length, 1); return Buffer.concat([head, buffer]); };
function unframe(body) {
  const messages = [];
  for (let i = 0; i + 5 <= body.length;) { const n = body.readUInt32BE(i + 1); messages.push(body.subarray(i + 5, i + 5 + n)); i += 5 + n; }
  return messages;
}

const helloRequest = (buffer) => {
  const out = { name: '', times: 0 };
  for (const f of read(buffer)) { if (f.field === 1) out.name = f.value.toString(); if (f.field === 2) out.times = Number(f.value); }
  return out;
};
const helloReply = (text, count, tags = []) => msg(
  str(1, text), num(2, count), num(3, 1), ...tags.map((t) => str(4, t)),
  len(5, msg(str(1, 'a'), num(2, 1))),
  len(6, msg(num(1, 1704067200), num(2, 500000000))));

// --- Handlers ---

function reflection(requests) {
  return requests.map((request) => {
    for (const f of read(request)) {
      if (f.field === 7) return msg(len(6, msg(len(1, str(1, 'demo.Greeter')), len(1, str(1, 'grpc.reflection.v1.ServerReflection')))));
      // The file for a symbol is sent without the files it imports, so clients must ask for those.
      if (f.field === 4) return f.value.toString().startsWith('demo.') ? msg(len(4, len(1, demoFile))) : msg(len(7, msg(num(1, 5), str(2, 'Symbol not found'))));
      if (f.field === 3) { const file = files[f.value.toString()]; return file ? msg(len(4, len(1, file))) : msg(len(7, msg(num(1, 5), str(2, 'File not found')))); }
    }
    return msg(len(7, msg(num(1, 3), str(2, 'Unknown request'))));
  });
}

const alphaOnly = process.argv.includes('alpha');
const reflectionPath = alphaOnly ? '/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo' : '/grpc.reflection.v1.ServerReflection/ServerReflectionInfo';

const server = http2.createServer();
server.on('stream', (stream, headers) => {
  const path = headers[':path'];
  const chunks = [];
  stream.on('data', (chunk) => chunks.push(chunk));
  stream.on('end', async () => {
    const requests = unframe(Buffer.concat(chunks));
    const fail = (code, text) => stream.respond(
      { ':status': 200, 'content-type': 'application/grpc', 'grpc-status': String(code), 'grpc-message': encodeURIComponent(text) }, { endStream: true });
    if ((headers['content-type'] || '').indexOf('application/grpc') !== 0) { stream.respond({ ':status': 415 }, { endStream: true }); return; }

    let replies;
    let gap = 0;
    if (path === reflectionPath) {
      replies = reflection(requests);
    } else if (path === '/demo.Greeter/SayHello') {
      const request = helloRequest(requests[0] || Buffer.alloc(0));
      const token = headers['x-token'];
      replies = [helloReply(`Hello, ${request.name || 'stranger'}`, request.times, token ? [token] : [])];
    } else if (path === '/demo.Greeter/Countdown') {
      const request = helloRequest(requests[0] || Buffer.alloc(0));
      replies = Array.from({ length: request.times }, (_, i) => helloReply(String(request.times - i), i + 1));
      gap = 40;
    } else if (path === '/demo.Greeter/Collect') {
      replies = [helloReply(requests.map((r) => helloRequest(r).name).join('+'), requests.length)];
    } else if (path === '/demo.Greeter/Fail') {
      return fail(5, 'No such pet: 100% gone');
    } else {
      return fail(12, `Method not found: ${path}`);
    }

    stream.respond({ ':status': 200, 'content-type': 'application/grpc' }, { waitForTrailers: true });
    stream.on('wantTrailers', () => stream.sendTrailers({ 'grpc-status': '0' }));
    for (const reply of replies) {
      if (stream.destroyed) return;
      stream.write(frame(reply));
      if (gap) await new Promise((resolve) => setTimeout(resolve, gap));
    }
    stream.end();
  });
});

server.listen(Number(process.argv[2]) || 0, '127.0.0.1', () => console.log(`PORT ${server.address().port}`));
