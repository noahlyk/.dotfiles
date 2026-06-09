#!/usr/bin/env node
const { OBSWebSocket } = require('obs-websocket-js');

(async () => {
  const obs = new OBSWebSocket();
  try {
    await obs.connect('ws://localhost:4455', '');
    const { outputActive } = await obs.call('GetReplayBufferStatus');
    if (!outputActive) await obs.call('StartReplayBuffer');
    await obs.call('SaveReplayBuffer');
    console.log('Done!');
  } catch (e) {
    console.error(e.message);
  } finally {
    await obs.disconnect();
  }
})();