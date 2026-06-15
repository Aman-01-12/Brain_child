// One-shot spike seed: create a user + team, mint a real access JWT, print the
// values the live round-trip XCTest needs. Run: node test/spikeSeed.js
// Prints a single JSON line to stdout: { baseURL, jwt, teamId, userId, email }.
require('dotenv').config({ quiet: true });
const h = require('./helpers');

(async () => {
  try {
    const user = await h.createUser();
    const teamId = await h.createTeam(user);
    const jwt = h.tokenFor(user);
    // Exit only after stdout has flushed: when stdout is a pipe (POSIX), writes
    // are async/buffered, so exiting immediately can truncate the JSON line.
    process.stdout.write(JSON.stringify({
      baseURL: `http://localhost:${process.env.PORT || 3000}`,
      jwt, teamId, userId: user.id, email: user.email,
    }) + '\n', () => process.exit(0));
  } catch (e) {
    console.error('[spikeSeed] error:', e.message);
    process.exit(1);
  }
})();
