// <copyright file="security.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

// Optional inbound bearer-token validation: anonymous unless EPP_REQUIRE_AUTH=true, which validates
// a Microsoft JWT (iss/aud/exp/RS256). Easy Auth is the primary gate; this is the backstop.

const jwksByTenant = new Map();

function getJwks(issuerTenantId) {
    if (!jwksByTenant.has(issuerTenantId)) {
        const { createRemoteJWKSet } = require('jose');
        jwksByTenant.set(
            issuerTenantId,
            createRemoteJWKSet(new URL(`https://login.microsoftonline.com/${issuerTenantId}/discovery/v2.0/keys`)),
        );
    }
    return jwksByTenant.get(issuerTenantId);
}

// azp is the v2 caller claim, appid the v1 one.
function isExpectedCaller(payload, expectedClientId) {
    if (!expectedClientId) return true;
    return (payload.azp || payload.appid) === expectedClientId;
}

async function validateToken(request, context, requestId) {
    if (String(process.env.EPP_REQUIRE_AUTH || 'false').toLowerCase() !== 'true') {
        return { ok: true, skipped: true };
    }

    const audience = process.env.EPP_EXPECTED_AUDIENCE;
    const tenantId = process.env.EPP_TENANT_ID;
    if (!audience || !tenantId) {
        return { ok: false, reason: 'EPP_REQUIRE_AUTH is set but EPP_EXPECTED_AUDIENCE / EPP_TENANT_ID are missing' };
    }

    const authorizationHeader = (request.headers.get('authorization') || '').trim();
    const bearerToken = authorizationHeader.slice(0, 7).toLowerCase() === 'bearer '
        ? authorizationHeader.slice(7).trim()
        : '';
    if (!bearerToken) return { ok: false, reason: 'missing bearer token' };

    try {
        const { jwtVerify } = require('jose');
        // Accept both the v2 and v1 issuer forms unless EPP_EXPECTED_ISSUER pins one.
        const issuers = process.env.EPP_EXPECTED_ISSUER
            ? [process.env.EPP_EXPECTED_ISSUER]
            : [
                `https://login.microsoftonline.com/${tenantId}/v2.0`,
                `https://sts.windows.net/${tenantId}/`,
            ];
        const { payload } = await jwtVerify(bearerToken, getJwks(tenantId), {
            audience,
            issuer: issuers,
            algorithms: ['RS256'],
        });

        if (!isExpectedCaller(payload, process.env.EPP_EXPECTED_CLIENT_ID)) {
            context.log(`[AUTH_FAIL] requestId=${requestId} reason=unexpected caller appid=${payload.azp || payload.appid || 'none'}`);
            return { ok: false, reason: 'unexpected caller' };
        }
        return { ok: true };
    } catch (error) {
        context.log(`[AUTH_FAIL] requestId=${requestId} reason=${error.message}`);
        return { ok: false, reason: 'token validation failed' };
    }
}

module.exports = { validateToken, isExpectedCaller };
