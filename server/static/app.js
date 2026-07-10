const espStatus = document.getElementById("esp-status");
const audioStatus = document.getElementById("audio-status");
const recordStatus = document.getElementById("record-status");
const imageStatus = document.getElementById("image-status");
const imageTime = document.getElementById("image-time");
const camera = document.getElementById("camera");
const meterFill = document.getElementById("meter-fill");
const thresholdLine = document.getElementById("threshold-line");
const currentDb = document.getElementById("current-db");
const thresholdInput = document.getElementById("threshold");
const thresholdValue = document.getElementById("threshold-value");
const transcripts = document.getElementById("transcripts");

function dbToPercent(db) {
  const clamped = Math.max(-60, Math.min(-10, db));
  return ((clamped + 60) / 50) * 100;
}

function setPill(el, text, state) {
  el.textContent = text;
  el.classList.remove("ok", "warn", "bad");
  if (state) el.classList.add(state);
}

function renderTranscripts(items) {
  if (!items || items.length === 0) {
    transcripts.innerHTML = '<li class="empty">Пока ничего не распознано. Говорите громче порога.</li>';
    return;
  }

  transcripts.innerHTML = items
    .map((item) => {
      const time = new Date(item.time * 1000).toLocaleTimeString();
      return `
        <li>
          <div class="meta">${time} · ${item.duration_ms} мс · пик ${item.peak_db} dB</div>
          <div class="text">${item.text}</div>
        </li>
      `;
    })
    .join("");
}

function updateUi(data) {
  setPill(
    espStatus,
    data.esp_online ? "BLE: подключено" : "BLE: поиск устройства",
    data.esp_online ? "ok" : "warn"
  );

  setPill(
    audioStatus,
    data.audio_connected ? "Аудио: принимаем" : "Аудио: нет BLE",
    data.audio_connected ? "ok" : "warn"
  );

  setPill(
    recordStatus,
    data.is_recording ? "Запись: идёт" : "Запись: выкл",
    data.is_recording ? "warn" : "ok"
  );

  if (data.has_image && data.image_updated_at) {
    const when = new Date(data.image_updated_at * 1000).toLocaleTimeString();
    setPill(imageStatus, `Снимок: ${when}`, "ok");
    imageTime.textContent = `(обновлён ${when})`;
    camera.src = `/api/camera/latest?ts=${data.image_updated_at}`;
  } else {
    setPill(imageStatus, "Снимок: ожидание", "warn");
    imageTime.textContent = "";
  }

  const db = data.current_db ?? -100;
  currentDb.textContent = `${db.toFixed(1)} dB`;
  meterFill.style.width = `${dbToPercent(db)}%`;

  const threshold = data.db_threshold ?? -35;
  thresholdLine.style.left = `${dbToPercent(threshold)}%`;
  thresholdValue.textContent = `${threshold} dB`;

  renderTranscripts(data.transcripts);
}

thresholdInput.addEventListener("input", async () => {
  const value = Number(thresholdInput.value);
  thresholdValue.textContent = `${value} dB`;
  thresholdLine.style.left = `${dbToPercent(value)}%`;

  await fetch("/api/threshold", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ db_threshold: value }),
  });
});

async function pollStatus() {
  try {
    const res = await fetch("/api/status");
    const data = await res.json();
    updateUi(data);
    thresholdInput.value = data.db_threshold;
  } catch (err) {
    setPill(espStatus, "Сервер: ошибка", "bad");
  }
}

pollStatus();
setInterval(pollStatus, 500);
