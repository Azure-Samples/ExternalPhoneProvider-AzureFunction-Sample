'use strict';

const infobip = require('./infobip');
const soprano = require('./soprano');
const telesign = require('./telesign');
const twilio = require('./twilio');

function selectProvider(name) {
    switch (String(name || '').trim().toLowerCase()) {
        case 'infobip': return infobip;
        case 'soprano': return soprano;
        case 'telesign': return telesign;
        case 'twilio': return twilio;
        default: return null;
    }
}

module.exports = { selectProvider, infobip, soprano, telesign, twilio };
