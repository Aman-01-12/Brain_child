// Unit tests — H5: file upload validation (shared fileValidation.js).
// Pure logic; no DB/Redis. Each assertion fails if the mitigation is weakened.

const { test, describe } = require('node:test');
const assert = require('node:assert');
const { isMimeAllowed, sanitizeFilename } = require('./../fileValidation');

describe('H5: file upload validation', () => {
  test('allows images, PDFs, text, and office documents', () => {
    assert.ok(isMimeAllowed('image/png'));
    assert.ok(isMimeAllowed('image/jpeg'));
    assert.ok(isMimeAllowed('application/pdf'));
    assert.ok(isMimeAllowed('text/plain'));
    assert.ok(isMimeAllowed('application/vnd.openxmlformats-officedocument.wordprocessingml.document'));
  });

  test('blocks executables and scripts regardless of prefix', () => {
    assert.ok(!isMimeAllowed('application/x-msdownload'));
    assert.ok(!isMimeAllowed('application/x-dosexec'));
    assert.ok(!isMimeAllowed('application/x-mach-binary'));
    assert.ok(!isMimeAllowed('application/x-sh'));
    assert.ok(!isMimeAllowed('application/x-shellscript'));
    assert.ok(!isMimeAllowed('application/javascript'));
  });

  test('rejects empty/unknown/null MIME', () => {
    assert.ok(!isMimeAllowed(''));
    assert.ok(!isMimeAllowed(null));
    assert.ok(!isMimeAllowed(undefined));
    assert.ok(!isMimeAllowed('application/octet-stream'));
  });

  test('sanitizeFilename strips path traversal and unsafe characters', () => {
    assert.strictEqual(sanitizeFilename('../../etc/passwd'), 'passwd');
    assert.strictEqual(sanitizeFilename('a b/c$d.txt'), 'c_d.txt'); // basename, then charset filter
    assert.strictEqual(sanitizeFilename(''), 'file');
    assert.strictEqual(sanitizeFilename(null), 'file');
  });

  test('sanitizeFilename caps length at 200', () => {
    assert.ok(sanitizeFilename('x'.repeat(500)).length <= 200);
  });
});
