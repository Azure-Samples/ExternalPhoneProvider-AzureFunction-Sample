'use strict';

const infobip = require('./infobip');
const sinch = require('./sinch');
const soprano = require('./soprano');
const telesign = require('./telesign');

function selectProvider(name) {
    switch (String(name || '').trim().toLowerCase()) {
        case 'infobip': return infobip;
        case 'sinch': return sinch;
        case 'soprano': return soprano;
        case 'telesign': return telesign;
        default: return null;
    }
}

module.exports = { selectProvider, infobip, sinch, soprano, telesign };
