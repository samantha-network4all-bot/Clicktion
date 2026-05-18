// Notebook page interactivity — follow-up input + SSE streaming.
//
// Wiring:
//   1. User types a message → submits form
//   2. POST /notebooks/{id}/follow-up with the message
//      Response: { job_id }
//   3. Append a markdown cell with the user's message (mirrors what the
//      server just persisted)
//   4. Open EventSource on /notebooks/{id}/stream?job=<job_id>
//   5. Append tokens into #streaming-cell as they arrive
//   6. On [DONE], move the streamed text into a permanent cell and reset
//      the streaming holder so the next turn can reuse it.

(() => {
  const form = document.getElementById('follow-up-form');
  const picker = document.getElementById('skill-picker');
  if (!form && !picker) return;

  const notebookID = (form || picker).dataset.notebook;
  const cellsContainer = document.querySelector('.cells');
  const streamingCell = document.getElementById('streaming-cell');
  const streamingBody = document.getElementById('streaming-body');

  // Convert a multi-line plain-text message into safe HTML.
  const escapeHtml = (s) => s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');

  const appendUserCell = (text) => {
    const cell = document.createElement('div');
    cell.className = 'cell cell-markdown';
    cell.innerHTML = `
      <div class="cell-label">You</div>
      <div class="cell-body">${escapeHtml(text)}</div>
    `;
    // Insert before the streaming cell so order matches what reload will show.
    cellsContainer.insertBefore(cell, streamingCell);
  };

  const promoteStreamingCell = (finalText) => {
    const cell = document.createElement('div');
    cell.className = 'cell cell-response';
    cell.innerHTML = `
      <div class="cell-label">Response</div>
      <div class="cell-body"></div>
    `;
    cell.querySelector('.cell-body').textContent = finalText;
    cellsContainer.insertBefore(cell, streamingCell);
    streamingBody.textContent = '';
    streamingCell.style.display = 'none';
  };

  let inflight = null;

  const startStream = (jobID, onDone) => {
    streamingBody.textContent = '';
    streamingCell.style.display = '';
    streamingCell.scrollIntoView({ behavior: 'smooth', block: 'end' });

    const es = new EventSource(`/notebooks/${notebookID}/stream?job=${encodeURIComponent(jobID)}`);
    let accumulated = '';
    inflight = es;

    es.onmessage = (ev) => {
      const data = ev.data;
      if (data === '[DONE]') {
        es.close();
        inflight = null;
        const text = accumulated.trim();
        if (text.length > 0) promoteStreamingCell(text);
        else streamingCell.style.display = 'none';
        if (onDone) onDone();
        return;
      }
      // Thinking tokens are prefixed with \x01 by the Go service. Skip them
      // here — P2.5 can add a separate "reasoning" pane.
      if (data.charCodeAt(0) === 0x01) return;
      accumulated += data;
      streamingBody.textContent = accumulated;
      streamingCell.scrollIntoView({ behavior: 'smooth', block: 'end' });
    };

    es.onerror = () => {
      es.close();
      inflight = null;
      streamingBody.textContent += '\n\n[stream error]';
    };
  };

  // Skill picker — first-time skill run on a fresh / todo notebook.
  if (picker) {
    picker.querySelectorAll('.skill-chip').forEach((btn) => {
      btn.addEventListener('click', async () => {
        if (inflight) return;
        const skillName = btn.dataset.skill;
        // Optimistic UI: dim the picker, mark this one as active.
        picker.querySelectorAll('.skill-chip').forEach((b) => (b.disabled = true));
        btn.classList.add('skill-chip-active');
        try {
          const resp = await fetch(`/notebooks/${notebookID}/run-skill`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ skill_name: skillName }),
          });
          if (!resp.ok) throw new Error(await resp.text());
          const { job_id } = await resp.json();
          startStream(job_id, () => {
            // On [DONE]: hide picker — refresh would show response cell now.
            picker.style.display = 'none';
          });
        } catch (err) {
          console.error(err);
          picker.querySelectorAll('.skill-chip').forEach((b) => (b.disabled = false));
          btn.classList.remove('skill-chip-active');
          alert(`Could not start skill: ${err.message || err}`);
        }
      });
    });
  }

  if (!form) return; // page is in skill-picker mode only

  // OCR edit — inline textarea swap on capture cells. Save persists via
  // POST /notebooks/{id}/edit-ocr and reloads the page so the new content
  // is reflected everywhere. Re-running against the fixed OCR is one extra
  // click on Regenerate.
  document.querySelectorAll('.ocr-edit-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      const captureID = btn.dataset.capture;
      const pre = document.querySelector(`.ocr-body[data-ocr-for="${captureID}"]`);
      if (!pre || pre.dataset.editing === '1') return;
      pre.dataset.editing = '1';

      const ta = document.createElement('textarea');
      ta.className = 'ocr-edit-area';
      ta.value = pre.textContent;
      ta.rows = Math.min(20, Math.max(4, pre.textContent.split('\n').length));
      const bar = document.createElement('div');
      bar.className = 'ocr-edit-bar';
      bar.innerHTML = `
        <button type="button" class="btn btn-primary ocr-save">Save</button>
        <button type="button" class="btn btn-ghost ocr-cancel">Cancel</button>
        <span class="ocr-edit-hint">Click Regenerate after saving to re-run the LLM against the new text.</span>
      `;
      pre.style.display = 'none';
      pre.parentNode.insertBefore(ta, pre.nextSibling);
      pre.parentNode.insertBefore(bar, ta.nextSibling);
      ta.focus();

      const close = () => {
        ta.remove();
        bar.remove();
        pre.style.display = '';
        delete pre.dataset.editing;
      };

      bar.querySelector('.ocr-cancel').addEventListener('click', close);
      bar.querySelector('.ocr-save').addEventListener('click', async () => {
        try {
          const resp = await fetch(`/notebooks/${notebookID}/edit-ocr`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ capture_id: captureID, ocr_text: ta.value }),
          });
          if (!resp.ok) throw new Error(await resp.text());
          // Reload so all the places that show OCR text (header, cell, etc.)
          // pick up the change.
          location.reload();
        } catch (err) {
          alert(`Could not save OCR: ${err.message || err}`);
        }
      });
    });
  });

  // Regenerate button — re-runs the most recent job without adding a user
  // message. Produces a new response variant appended below the existing one.
  const regenBtn = document.getElementById('regen-btn');
  if (regenBtn) {
    regenBtn.addEventListener('click', async () => {
      if (inflight) return;
      regenBtn.disabled = true;
      try {
        const resp = await fetch(`/notebooks/${notebookID}/regenerate`, { method: 'POST' });
        if (!resp.ok) throw new Error(await resp.text());
        const { job_id } = await resp.json();
        startStream(job_id, () => { regenBtn.disabled = false; });
      } catch (err) {
        regenBtn.disabled = false;
        alert(`Could not regenerate: ${err.message || err}`);
      }
    });
  }

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (inflight) return; // ignore submits while a turn is in progress

    const ta = form.querySelector('textarea[name="message"]');
    const text = (ta.value || '').trim();
    if (!text) return;

    appendUserCell(text);
    ta.value = '';

    try {
      const resp = await fetch(`/notebooks/${notebookID}/follow-up`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: text }),
      });
      if (!resp.ok) throw new Error(await resp.text());
      const { job_id } = await resp.json();
      startStream(job_id);
    } catch (err) {
      console.error(err);
      const note = document.createElement('div');
      note.className = 'empty-card';
      note.textContent = `Could not send: ${err.message || err}`;
      cellsContainer.insertBefore(note, streamingCell);
    }
  });

  // ⌘↩ to send.
  form.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      form.requestSubmit();
    }
  });
})();
