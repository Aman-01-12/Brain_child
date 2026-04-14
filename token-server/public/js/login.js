const form     = document.getElementById('loginForm');
const errorEl  = document.getElementById('errorMsg');
const submitEl = document.getElementById('submitBtn');

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  errorEl.classList.remove('visible');
  submitEl.disabled = true;

  const email    = document.getElementById('email').value.trim();
  const password = document.getElementById('password').value;

  if (!email || password.length < 8) {
    showError('Email and password (8+ characters) are required.');
    submitEl.disabled = false;
    return;
  }

  try {
    const res = await fetch('/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password }),
    });

    let data;
    const text = await res.text().catch(() => '');
    try {
      data = JSON.parse(text);
    } catch {
      showError(text || 'Login failed. Please try again.');
      submitEl.disabled = false;
      return;
    }

    if (!res.ok) {
      showError(data.error || 'Login failed. Please try again.');
      submitEl.disabled = false;
      return;
    }

    // Create a handoff code via the server so the Mac app can retrieve tokens securely
    const exchangeRes = await fetch('/auth/oauth/create-handoff', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + data.accessToken,
      },
    });

    if (exchangeRes.ok) {
      let exchangeData;
      try {
        exchangeData = await exchangeRes.json();
      } catch {
        showError('Handoff response invalid. Please try again.');
        submitEl.disabled = false;
        return;
      }
      if (exchangeData.code) {
        window.location = 'com-inter-app://oauth-callback?code=' + encodeURIComponent(exchangeData.code);
      } else {
        showError('Handoff response missing code. Please try again.');
        submitEl.disabled = false;
      }
    } else {
      showError('Handoff failed. Please use the Inter app directly.');
      submitEl.disabled = false;
    }
  } catch (err) {
    showError('Network error. Please check your connection.');
    submitEl.disabled = false;
  }
});

function showError(msg) {
  errorEl.textContent = msg;
  errorEl.classList.add('visible');
}
