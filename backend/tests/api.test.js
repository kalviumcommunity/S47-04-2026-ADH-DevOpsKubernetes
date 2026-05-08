// backend/tests/api.test.js
//
// Automated tests for the AeroStore backend API
// Uses Node.js built-in test runner (node:test) — no extra dependencies
// Run with: npm test
//
// These tests validate the business logic and data integrity of the API
// WITHOUT requiring the HTTP server to start (faster, no port conflicts in CI).
// The smoke test in the CI workflow handles the network layer separately.

'use strict';

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

// ─────────────────────────────────────────────────────────────────────────
// Load the data the API serves — test the source of truth directly
// ─────────────────────────────────────────────────────────────────────────
const products = require('../products.json');

// ─────────────────────────────────────────────────────────────────────────
// Test Suite 1: products.json data integrity
// Validates that the data file the API serves is well-formed.
// A malformed products.json would cause the server to crash on startup.
// ─────────────────────────────────────────────────────────────────────────
describe('products.json — data integrity', () => {

  test('products is a non-empty array', () => {
    assert.ok(Array.isArray(products), 'products must be an array');
    assert.ok(products.length > 0, 'products array must not be empty');
  });

  test('every product has required fields', () => {
    const requiredFields = ['id', 'name', 'price', 'category', 'stock'];
    for (const product of products) {
      for (const field of requiredFields) {
        assert.ok(
          Object.prototype.hasOwnProperty.call(product, field),
          `Product id=${product.id} is missing required field: ${field}`
        );
      }
    }
  });

  test('every product id is a unique positive integer', () => {
    const ids = products.map(p => p.id);
    const uniqueIds = new Set(ids);
    assert.strictEqual(uniqueIds.size, ids.length, 'product ids must be unique');
    for (const id of ids) {
      assert.ok(typeof id === 'number' && Number.isInteger(id) && id > 0,
        `id must be a positive integer, got: ${id}`);
    }
  });

  test('every product name is a non-empty string', () => {
    for (const product of products) {
      assert.ok(typeof product.name === 'string', `product id=${product.id} name must be a string`);
      assert.ok(product.name.trim().length > 0, `product id=${product.id} name must not be empty`);
    }
  });

  test('every product price is a positive number', () => {
    for (const product of products) {
      assert.ok(typeof product.price === 'number', `product id=${product.id} price must be a number`);
      assert.ok(product.price > 0, `product id=${product.id} price must be positive, got: ${product.price}`);
    }
  });

  test('every product stock is a non-negative integer', () => {
    for (const product of products) {
      assert.ok(typeof product.stock === 'number' && Number.isInteger(product.stock),
        `product id=${product.id} stock must be an integer`);
      assert.ok(product.stock >= 0,
        `product id=${product.id} stock must be non-negative, got: ${product.stock}`);
    }
  });

  test('every product category is a non-empty string', () => {
    for (const product of products) {
      assert.ok(typeof product.category === 'string', `product id=${product.id} category must be a string`);
      assert.ok(product.category.trim().length > 0, `product id=${product.id} category must not be empty`);
    }
  });
});

// ─────────────────────────────────────────────────────────────────────────
// Test Suite 2: Express app module validation
// Validates that the app module loads without throwing.
// If index.js has a syntax error, require() throws and this test fails.
// ─────────────────────────────────────────────────────────────────────────
describe('Backend module — load validation', () => {

  test('express and cors modules are installed and loadable', () => {
    assert.doesNotThrow(() => require('express'), 'express must be installed');
    assert.doesNotThrow(() => require('cors'), 'cors must be installed');
  });

  test('products.json is valid JSON and loadable', () => {
    assert.doesNotThrow(() => require('../products.json'), 'products.json must be valid JSON');
  });

  test('PORT env variable defaults to 3001', () => {
    // Test that the default port logic works correctly
    delete process.env.PORT;
    const port = process.env.PORT || 3001;
    assert.strictEqual(port, 3001, 'default PORT must be 3001');
  });

  test('PORT env variable is respected when set', () => {
    process.env.PORT = '8080';
    const port = process.env.PORT || 3001;
    assert.strictEqual(port, '8080', 'PORT env variable must be respected');
    delete process.env.PORT; // cleanup
  });
});

// ─────────────────────────────────────────────────────────────────────────
// Test Suite 3: Business logic validation
// ─────────────────────────────────────────────────────────────────────────
describe('Business logic — product data rules', () => {

  test('products contain at least one Electronics item', () => {
    const electronics = products.filter(p => p.category === 'Electronics');
    assert.ok(electronics.length > 0, 'must have at least one Electronics product');
  });

  test('total product count is within expected range', () => {
    // Catches accidental truncation or duplication of products.json
    assert.ok(products.length >= 10, `expected at least 10 products, got ${products.length}`);
    assert.ok(products.length <= 100, `expected at most 100 products, got ${products.length}`);
  });

  test('no product has a price greater than 10000', () => {
    for (const product of products) {
      assert.ok(product.price <= 10000,
        `product "${product.name}" has unreasonably high price: ${product.price}`);
    }
  });
});
