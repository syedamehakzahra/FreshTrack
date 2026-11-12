import assert from 'node:assert/strict';
import { before, beforeEach, describe, it } from 'node:test';

const HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
const PROJECT_ID = process.env.GCLOUD_PROJECT || 'fresh-track-ca4b6';
const BASE_URL = `http://${HOST}/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
const CLEAR_URL = `http://${HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`;

function base64Url(obj) {
  return Buffer.from(JSON.stringify(obj), 'utf8').toString('base64url');
}

function makeAuthToken(uid) {
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url({ alg: 'none', kid: '' });
  const payload = base64Url({
    iss: `https://securetoken.google.com/${PROJECT_ID}`,
    aud: PROJECT_ID,
    auth_time: now,
    user_id: uid,
    sub: uid,
    iat: now,
    exp: now + 3600,
    email: `${uid}@example.com`,
    email_verified: true,
    firebase: {
      identities: { email: [`${uid}@example.com`] },
      sign_in_provider: 'password',
    },
  });
  return `${header}.${payload}.`;
}

function headersFor(uid) {
  if (uid === null) return { 'Content-Type': 'application/json' };
  if (uid === 'OWNER') {
    return {
      'Content-Type': 'application/json',
      Authorization: 'Bearer owner',
    };
  }
  return {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${makeAuthToken(uid)}`,
  };
}

async function createDoc(collectionPath, docId, fields, uid) {
  const res = await fetch(`${BASE_URL}/${collectionPath}?documentId=${docId}`, {
    method: 'POST',
    headers: headersFor(uid),
    body: JSON.stringify({ fields }),
  });
  return { status: res.status, body: await res.json().catch(() => ({})) };
}

async function setDoc(docPath, fields, uid) {
  const res = await fetch(`${BASE_URL}/${docPath}`, {
    method: 'PATCH',
    headers: headersFor(uid),
    body: JSON.stringify({ fields }),
  });
  return { status: res.status, body: await res.json().catch(() => ({})) };
}

async function patchDoc(docPath, fields, maskPaths, uid) {
  const maskQuery = maskPaths
    .map((p) => `updateMask.fieldPaths=${encodeURIComponent(p)}`)
    .join('&');
  const res = await fetch(`${BASE_URL}/${docPath}?${maskQuery}`, {
    method: 'PATCH',
    headers: headersFor(uid),
    body: JSON.stringify({ fields }),
  });
  return { status: res.status, body: await res.json().catch(() => ({})) };
}

async function getDoc(path, uid) {
  const res = await fetch(`${BASE_URL}/${path}`, {
    method: 'GET',
    headers: headersFor(uid),
  });
  return { status: res.status, body: await res.json().catch(() => ({})) };
}

async function deleteDoc(docPath, uid) {
  const res = await fetch(`${BASE_URL}/${docPath}`, {
    method: 'DELETE',
    headers: headersFor(uid),
  });
  return { status: res.status, body: await res.json().catch(() => ({})) };
}

function validPantryFields(overrides = {}) {
  return {
    name: { stringValue: 'Fresh Milk' },
    category: { stringValue: 'Dairy' },
    storageLocation: { stringValue: 'Fridge' },
    quantity: { integerValue: '2' },
    originalQuantity: { integerValue: '2' },
    totalPrice: { doubleValue: 500.0 },
    expiryDate: { timestampValue: '2026-11-25T00:00:00Z' },
    ...overrides,
  };
}

function validShoppingFields(overrides = {}) {
  return {
    name: { stringValue: 'Milk' },
    normalizedName: { stringValue: 'milk' },
    category: { stringValue: 'Dairy' },
    storageLocation: { stringValue: 'Fridge' },
    quantity: { integerValue: '2' },
    isChecked: { booleanValue: false },
    source: { stringValue: 'manual' },
    createdAt: { timestampValue: '2026-11-10T10:00:00Z' },
    updatedAt: { timestampValue: '2026-11-10T10:00:00Z' },
    ...overrides,
  };
}

function validWasteLogFields(overrides = {}) {
  return {
    foodName: { stringValue: 'Milk' },
    category: { stringValue: 'Dairy' },
    quantity: { integerValue: '1' },
    action: { stringValue: 'consumed' },
    timestamp: { timestampValue: '2026-11-10T10:00:00Z' },
    ...overrides,
  };
}

describe('FreshTrack Firestore Security Rules', () => {
  before(async () => {
    const ping = await fetch(BASE_URL).catch((e) => e);
    assert.ok(
      !(ping instanceof Error),
      `Firestore emulator must be running at ${HOST}`,
    );
  });

  beforeEach(async () => {
    const res = await fetch(CLEAR_URL, { method: 'DELETE' });
    assert.equal(res.status, 200);
  });

  it('rejects unauthenticated access across all user collections', async () => {
    assert.equal((await getDoc('users/userA', null)).status, 403);
    assert.equal((await getDoc('users/userA/items', null)).status, 403);
    assert.equal(
      (await createDoc('users/userA/items', 'm1', validPantryFields(), null)).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/shopping_list', 's1', validShoppingFields(), null)).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/waste_logs', 'w1', { foodName: { stringValue: 'Milk' } }, null)).status,
      403,
    );
  });

  it('enforces strict user isolation and rejects cross-user reads and writes', async () => {
    // Seed userA profile, pantry item, shopping item, and waste log as userA.
    assert.equal(
      (await setDoc('users/userA', { uid: { stringValue: 'userA' } }, 'userA')).status,
      200,
    );
    assert.equal(
      (await createDoc('users/userA/items', 'milk_1', validPantryFields(), 'userA')).status,
      200,
    );
    assert.equal(
      (await createDoc('users/userA/shopping_list', 'item_milk', validShoppingFields(), 'userA')).status,
      200,
    );
    assert.equal(
      (
        await createDoc(
          'users/userA/waste_logs',
          'log_1',
          {
            foodName: { stringValue: 'Milk' },
            category: { stringValue: 'Dairy' },
            quantity: { integerValue: '1' },
            action: { stringValue: 'consumed' },
            timestamp: { timestampValue: '2026-11-10T10:00:00Z' },
          },
          'userA',
        )
      ).status,
      200,
    );

    // Owner userA can read their own data.
    assert.equal((await getDoc('users/userA/items/milk_1', 'userA')).status, 200);
    assert.equal((await getDoc('users/userA/shopping_list/item_milk', 'userA')).status, 200);

    // Cross-user userB MUST be rejected on reads, creates, updates, and deletes!
    assert.equal((await getDoc('users/userA', 'userB')).status, 403);
    assert.equal((await getDoc('users/userA/items', 'userB')).status, 403);
    assert.equal((await getDoc('users/userA/items/milk_1', 'userB')).status, 403);
    assert.equal((await getDoc('users/userA/shopping_list', 'userB')).status, 403);
    assert.equal((await getDoc('users/userA/shopping_list/item_milk', 'userB')).status, 403);
    assert.equal((await getDoc('users/userA/waste_logs', 'userB')).status, 403);

    assert.equal(
      (await createDoc('users/userA/items', 'evil', validPantryFields(), 'userB')).status,
      403,
    );
    assert.equal(
      (await patchDoc('users/userA/items/milk_1', { quantity: { integerValue: '99' } }, ['quantity'], 'userB')).status,
      403,
    );
    assert.equal((await deleteDoc('users/userA/items/milk_1', 'userB')).status, 403);

    assert.equal(
      (await createDoc('users/userA/shopping_list', 'evil_s', validShoppingFields(), 'userB')).status,
      403,
    );
    assert.equal(
      (await patchDoc('users/userA/shopping_list/item_milk', { isChecked: { booleanValue: true } }, ['isChecked'], 'userB')).status,
      403,
    );
    assert.equal((await deleteDoc('users/userA/shopping_list/item_milk', 'userB')).status, 403);

    assert.equal((await deleteDoc('users/userA/waste_logs/log_1', 'userB')).status, 403);
  });

  it('validates Pantry field types, quantity bounds, and allows manual past expiry & legacy updates', async () => {
    // Valid priced, unpriced (null totalPrice), and manual past expiry date all pass.
    assert.equal(
      (await createDoc('users/userA/items', 'p1', validPantryFields(), 'userA')).status,
      200,
    );
    assert.equal(
      (
        await createDoc(
          'users/userA/items',
          'p2',
          validPantryFields({
            totalPrice: { nullValue: null },
            expiryDate: { timestampValue: '2023-01-01T00:00:00Z' },
          }),
          'userA',
        )
      ).status,
      200,
    );

    // Partial consumption update works cleanly.
    assert.equal(
      (await patchDoc('users/userA/items/p1', { quantity: { integerValue: '1' } }, ['quantity'], 'userA')).status,
      200,
    );

    // Pre-existing legacy item without storageLocation can still be partially consumed.
    await createDoc(
      'users/userA/items',
      'legacy1',
      {
        name: { stringValue: 'Rice' },
        category: { stringValue: 'Other' },
        quantity: { integerValue: '3' },
        expiryDate: { timestampValue: '2026-12-01T00:00:00Z' },
      },
      'OWNER',
    );
    assert.equal(
      (
        await patchDoc(
          'users/userA/items/legacy1',
          { quantity: { integerValue: '2' }, originalQuantity: { integerValue: '3' } },
          ['quantity', 'originalQuantity'],
          'userA',
        )
      ).status,
      200,
    );

    // Invalid Pantry payloads MUST fail!
    assert.equal(
      (await createDoc('users/userA/items', 'bad_qty_zero', validPantryFields({ quantity: { integerValue: '0' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/items', 'bad_qty_float', validPantryFields({ quantity: { doubleValue: 1.5 } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/items', 'bad_orig', validPantryFields({ quantity: { integerValue: '3' }, originalQuantity: { integerValue: '2' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/items', 'bad_name', validPantryFields({ name: { stringValue: '   ' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/items', 'bad_storage', validPantryFields({ storageLocation: { stringValue: 'Garage' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/items', 'bad_price_neg', validPantryFields({ totalPrice: { doubleValue: -10 } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/items', 'bad_price_zero', validPantryFields({ totalPrice: { integerValue: '0' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/items', 'bad_expiry_type', validPantryFields({ expiryDate: { stringValue: '2026-11-25' } }), 'userA')).status,
      403,
    );
  });

  it('validates Shopping List field types, quantity >= 1, and allowed enums', async () => {
    assert.equal(
      (await createDoc('users/userA/shopping_list', 's1', validShoppingFields(), 'userA')).status,
      200,
    );
    assert.equal(
      (
        await patchDoc(
          'users/userA/shopping_list/s1',
          {
            isChecked: { booleanValue: true },
            quantity: { integerValue: '3' },
            updatedAt: { timestampValue: '2026-11-10T10:05:00Z' },
          },
          ['isChecked', 'quantity', 'updatedAt'],
          'userA',
        )
      ).status,
      200,
    );

    // Invalid Shopping List writes rejected.
    assert.equal(
      (await createDoc('users/userA/shopping_list', 'bad_qty', validShoppingFields({ quantity: { integerValue: '0' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/shopping_list', 'bad_checked', validShoppingFields({ isChecked: { stringValue: 'true' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/shopping_list', 'bad_source', validShoppingFields({ source: { stringValue: 'ai_guess' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/shopping_list', 'bad_storage', validShoppingFields({ storageLocation: { stringValue: 'Balcony' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/shopping_list', 'bad_name', validShoppingFields({ name: { stringValue: '' } }), 'userA')).status,
      403,
    );
  });

  it('validates WasteLog schema fields and protects historical logs from updates or deletion', async () => {
    // Valid minimal unpriced log and full priced partial-disposal log both succeed.
    assert.equal(
      (await createDoc('users/userA/waste_logs', 'w_unpriced', validWasteLogFields(), 'userA')).status,
      200,
    );
    assert.equal(
      (
        await createDoc(
          'users/userA/waste_logs',
          'w_priced',
          validWasteLogFields({
            action: { stringValue: 'wasted' },
            quantity: { integerValue: '2' },
            sourceItemId: { stringValue: 'batch_milk_1' },
            originalQuantity: { integerValue: '4' },
            originalTotalPrice: { doubleValue: 1000.0 },
            financialValue: { doubleValue: 500.0 },
          }),
          'userA',
        )
      ).status,
      200,
    );
    // Rounding tiny financial values down to 0.0 is permitted.
    assert.equal(
      (
        await createDoc(
          'users/userA/waste_logs',
          'w_zero_val',
          validWasteLogFields({
            originalQuantity: { integerValue: '1000' },
            originalTotalPrice: { doubleValue: 1.0 },
            financialValue: { doubleValue: 0.0 },
          }),
          'userA',
        )
      ).status,
      200,
    );

    // Owner cannot mutate or delete historical waste_logs entries once created.
    assert.equal(
      (await patchDoc('users/userA/waste_logs/w_priced', { quantity: { integerValue: '99' } }, ['quantity'], 'userA')).status,
      403,
    );
    assert.equal(
      (await setDoc('users/userA/waste_logs/w_priced', validWasteLogFields({ quantity: { integerValue: '99' } }), 'userA')).status,
      403,
    );
    assert.equal((await deleteDoc('users/userA/waste_logs/w_priced', 'userA')).status, 403);

    // Cross-user waste_log writes and reads also rejected.
    assert.equal(
      (await createDoc('users/userA/waste_logs', 'evil_log', validWasteLogFields(), 'userB')).status,
      403,
    );
    assert.equal((await getDoc('users/userA/waste_logs/w_priced', 'userB')).status, 403);

    // Invalid WasteLog payloads MUST fail!
    assert.equal(
      (await createDoc('users/userA/waste_logs', 'bad_empty_name', validWasteLogFields({ foodName: { stringValue: '  ' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/waste_logs', 'bad_long_name', validWasteLogFields({ foodName: { stringValue: 'a'.repeat(501) } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/waste_logs', 'bad_qty_zero', validWasteLogFields({ quantity: { integerValue: '0' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/waste_logs', 'bad_qty_float', validWasteLogFields({ quantity: { doubleValue: 1.5 } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/waste_logs', 'bad_action', validWasteLogFields({ action: { stringValue: 'expired' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/waste_logs', 'bad_ts', validWasteLogFields({ timestamp: { stringValue: '2026-11-10' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (
        await createDoc(
          'users/userA/waste_logs',
          'bad_orig_qty',
          validWasteLogFields({
            quantity: { integerValue: '3' },
            originalQuantity: { integerValue: '2' },
          }),
          'userA',
        )
      ).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/waste_logs', 'bad_orig_price', validWasteLogFields({ originalTotalPrice: { integerValue: '0' } }), 'userA')).status,
      403,
    );
    assert.equal(
      (await createDoc('users/userA/waste_logs', 'bad_fin_val', validWasteLogFields({ financialValue: { doubleValue: -1.0 } }), 'userA')).status,
      403,
    );
  });
});
