'use strict';

const VOICE_PASSCODE_PATTERN = /(?<![0-9])[0-9]{6}(?![0-9])/g;

function buildVoiceMessage(message) {
    const paced = message.replace(VOICE_PASSCODE_PATTERN, (passcode) => [...passcode].join(', '));
    return `${paced} ${paced}`;
}

module.exports = { buildVoiceMessage };
