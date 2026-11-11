'use strict';

function buildVoiceMessage(message, otp) {
    const paced = otp ? message.replaceAll(otp, () => [...otp].join(', ')) : message;
    return `${paced} ${paced}`;
}

module.exports = { buildVoiceMessage };
