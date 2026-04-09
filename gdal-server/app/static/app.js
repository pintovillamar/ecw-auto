const dropZone = document.getElementById("dropZone");
const fileInput = document.getElementById("fileInput");
const fileName = document.getElementById("fileName");
const submitBtn = document.getElementById("submitBtn");
const uploadForm = document.getElementById("uploadForm");
const optionsHeader = document.getElementById("optionsHeader");
const optionsBody = document.getElementById("optionsBody");
const jobSection = document.getElementById("jobSection");
const jobTitle = document.getElementById("jobTitle");
const jobMeta = document.getElementById("jobMeta");
const progressFill = document.getElementById("progressFill");
const jobStatus = document.getElementById("jobStatus");
const logsSection = document.getElementById("logsSection");
const logsBox = document.getElementById("logsBox");
const outputsList = document.getElementById("outputsList");

let currentJobId = null;
let pollInterval = null;

// Drop zone events
dropZone.addEventListener("click", () => fileInput.click());

dropZone.addEventListener("dragover", (e) => {
  e.preventDefault();
  dropZone.classList.add("dragover");
});

dropZone.addEventListener("dragleave", () => {
  dropZone.classList.remove("dragover");
});

dropZone.addEventListener("drop", (e) => {
  e.preventDefault();
  dropZone.classList.remove("dragover");
  if (e.dataTransfer.files.length > 0) {
    fileInput.files = e.dataTransfer.files;
    handleFileSelect();
  }
});

fileInput.addEventListener("change", handleFileSelect);

function handleFileSelect() {
  if (fileInput.files.length > 0) {
    const file = fileInput.files[0];
    fileName.textContent = file.name;
    dropZone.classList.add("has-file");
    submitBtn.disabled = false;

    // Auto-fill output name
    const outputInput = document.getElementById("outputName");
    if (outputInput && !outputInput.value) {
      const base = file.name.replace(/\.[^.]+$/, "");
      outputInput.value = base;
    }
  }
}

// Options toggle
optionsHeader.addEventListener("click", () => {
  optionsHeader.classList.toggle("open");
  optionsBody.classList.toggle("open");
});

// Form submit
uploadForm.addEventListener("submit", async (e) => {
  e.preventDefault();

  if (!fileInput.files.length) return;

  submitBtn.disabled = true;
  submitBtn.textContent = "Uploading...";

  const formData = new FormData(uploadForm);

  try {
    const res = await fetch("/api/jobs", {
      method: "POST",
      body: formData,
    });

    const data = await res.json();

    if (!res.ok) {
      alert(data.error || "Upload failed");
      submitBtn.disabled = false;
      submitBtn.textContent = "Start Conversion";
      return;
    }

    currentJobId = data.job_id;
    showJobSection();
    startPolling();

    // Reset form
    fileInput.value = "";
    fileName.textContent = "";
    dropZone.classList.remove("has-file");
    submitBtn.textContent = "Start Conversion";
  } catch (err) {
    alert("Network error: " + err.message);
    submitBtn.disabled = false;
    submitBtn.textContent = "Start Conversion";
  }
});

function showJobSection() {
  jobSection.classList.add("visible");
  logsSection.classList.add("visible");
}

function startPolling() {
  if (pollInterval) clearInterval(pollInterval);
  pollInterval = setInterval(pollJob, 2000);
  pollJob(); // Immediate first poll
}

async function pollJob() {
  if (!currentJobId) return;

  try {
    const [statusRes, logsRes] = await Promise.all([
      fetch(`/api/jobs/${currentJobId}`),
      fetch(`/api/jobs/${currentJobId}/logs?tail=50`),
    ]);

    const status = await statusRes.json();
    const logsData = await logsRes.json();

    updateJobDisplay(status);
    updateLogs(logsData.logs || []);

    if (status.status === "completed" || status.status === "failed") {
      clearInterval(pollInterval);
      pollInterval = null;
      submitBtn.disabled = false;
      loadOutputs();
    }
  } catch (err) {
    console.error("Poll error:", err);
  }
}

function updateJobDisplay(job) {
  jobTitle.textContent = `${job.filename} → ${job.output_name}.mbtiles`;
  jobMeta.textContent = `Job ${job.id} · ${job.status}`;

  progressFill.style.width = `${job.progress}%`;
  progressFill.classList.remove("done", "error");

  if (job.status === "completed") {
    progressFill.classList.add("done");
  } else if (job.status === "failed") {
    progressFill.classList.add("error");
  }

  jobStatus.textContent = job.message || job.stage;
}

function updateLogs(logs) {
  logsBox.textContent = logs.join("\n");
  logsBox.scrollTop = logsBox.scrollHeight;
}

function getTileServerBase() {
  // Tileserver is on same host, port 8081
  return `${window.location.protocol}//${window.location.hostname}:8081`;
}

function getLayerName(filename) {
  // Strip .mbtiles extension and replace spaces with underscores (matches tileserver entrypoint.sh)
  return filename.replace(/\.mbtiles$/, "").replace(/ /g, "_");
}

async function loadOutputs() {
  try {
    const res = await fetch("/api/outputs");
    const outputs = await res.json();

    if (outputs.length === 0) {
      outputsList.innerHTML = '<div class="empty-state">No outputs yet</div>';
      return;
    }

    const tileBase = getTileServerBase();

    outputsList.innerHTML = outputs
      .map((o) => {
        const layer = getLayerName(o.name);
        const tileJsonUrl = `${tileBase}/data/${layer}.json`;
        const xyzUrl = `${tileBase}/data/${layer}/{z}/{x}/{y}.png`;

        return `
      <div class="output-item">
        <div class="output-info">
          <span class="output-name">${o.name}</span>
          <span class="output-size">${formatSize(o.size)}</span>
        </div>
        <div class="output-links">
          <a href="${tileJsonUrl}" target="_blank" rel="noopener" class="tile-link tilejson-link" title="Open TileJSON metadata">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><polyline points="10 9 9 9 8 9"/></svg>
            TileJSON
          </a>
          <button class="tile-link xyz-link" title="Copy XYZ URL to clipboard" onclick="copyXyz(this, '${xyzUrl}')">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
            XYZ
          </button>
        </div>
      </div>
    `;
      })
      .join("");
  } catch (err) {
    console.error("Failed to load outputs:", err);
  }
}

function copyXyz(btn, url) {
  navigator.clipboard.writeText(url).then(() => {
    const original = btn.innerHTML;
    btn.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg> Copied!`;
    btn.classList.add("copied");
    setTimeout(() => {
      btn.innerHTML = original;
      btn.classList.remove("copied");
    }, 2000);
  });
}

function formatSize(bytes) {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + " MB";
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + " GB";
}

// Load outputs on page load
loadOutputs();
