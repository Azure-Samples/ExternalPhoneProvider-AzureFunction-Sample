// <copyright file="security.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

// Inbound Microsoft JWT validation (iss/aud/exp/RS256). Local no-auth is supported explicitly;
// on Azure it must be enabled with a pinned caller, regardless of Easy Auth headers.

const { readConfig } = require('./config');
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
    const callerId = payload.azp || payload.appid;
    return typeof callerId === 'string' && callerId.toLowerCase() === expectedClientId.toLowerCase();
}

async function validateToken(request, config = readConfig()) {
    const { env, requireAuth, expectedClientId, expectedAudience: audience, tenantId, expectedIssuer } = config;
    const onAzure = !!(env.WEBSITE_INSTANCE_ID || env.WEBSITE_HOSTNAME || env.WEBSITE_SITE_NAME);
    if (onAzure && !requireAuth) {
        return { ok: false, reason: 'EPP_REQUIRE_AUTH must be true on Azure' };
    }
    if (!requireAuth) {
        return { ok: true, skipped: true };
    }

    if (onAzure && !expectedClientId) {
        return { ok: false, reason: 'EPP_EXPECTED_CLIENT_ID is required on Azure' };
    }

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
        const issuers = expectedIssuer
            ? [expectedIssuer]
            : [
                `https://login.microsoftonline.com/${tenantId}/v2.0`,
                `https://sts.windows.net/${tenantId}/`,
            ];
        const { payload } = await jwtVerify(bearerToken, getJwks(tenantId), {
            audience,
            issuer: issuers,
            algorithms: ['RS256'],
            requiredClaims: ['exp'],
        });

        if (!isExpectedCaller(payload, expectedClientId)) {
            return { ok: false, reason: 'unexpected caller' };
        }
        return { ok: true };
    } catch {
        return { ok: false, reason: 'token validation failed' };
    }
}

module.exports = { validateToken, isExpectedCaller };
