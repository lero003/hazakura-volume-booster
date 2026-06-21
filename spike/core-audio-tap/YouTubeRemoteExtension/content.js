(() => {
  const runtimeApi = globalThis.browser ?? globalThis.chrome;
  const rootId = "hazakura-amp-floating-bar";
  const storageDefaults = {
    hazakuraAmpCollapsed: false,
    hazakuraAmpRepeatEnabled: false,
    hazakuraAmpPosition: null
  };
  const boostPresets = [100, 150, 200, 300, 400];
  const staleStateThresholdMs = 5_000;
  const statePollIntervalMs = 3_000;

  let root;
  let header;
  let boostInput;
  let boostValue;
  let boostSafetyText;
  let statusText;
  let repeatButton;
  let collapseButton;
  let presetButtons = [];
  let repeatEnabled = false;
  let collapsed = false;
  let savedPosition = null;
  let dragState = null;
  let lastUrl = location.href;
  let sendTimer;

  function isWatchPage() {
    return location.hostname.endsWith("youtube.com") && location.pathname === "/watch";
  }

  function runtimeSend(payload) {
    if (!runtimeApi?.runtime?.sendMessage) {
      return Promise.resolve({ ok: false, error: "Extension runtime unavailable" });
    }

    const message = { target: "hazakuraAmp", payload };
    const response = runtimeApi.runtime.sendMessage(message);
    if (response && typeof response.then === "function") {
      return response;
    }

    return new Promise((resolve) => {
      runtimeApi.runtime.sendMessage(message, resolve);
    });
  }

  function storageGet(defaults) {
    if (!runtimeApi?.storage?.local) {
      return Promise.resolve(defaults);
    }
    const response = runtimeApi.storage.local.get(defaults);
    if (response && typeof response.then === "function") {
      return response;
    }
    return new Promise((resolve) => runtimeApi.storage.local.get(defaults, resolve));
  }

  function storageSet(values) {
    if (!runtimeApi?.storage?.local) {
      return;
    }
    runtimeApi.storage.local.set(values);
  }

  function isPosition(value) {
    return value
      && typeof value.x === "number"
      && typeof value.y === "number"
      && Number.isFinite(value.x)
      && Number.isFinite(value.y);
  }

  function clampPosition(position) {
    if (!root) {
      return position;
    }
    const margin = 12;
    const width = root.offsetWidth || 286;
    const height = root.offsetHeight || 120;
    const maxX = Math.max(margin, window.innerWidth - width - margin);
    const maxY = Math.max(margin, window.innerHeight - height - margin);
    return {
      x: Math.min(Math.max(position.x, margin), maxX),
      y: Math.min(Math.max(position.y, margin), maxY)
    };
  }

  function applyPosition(position, persist = false) {
    if (!root || !isPosition(position)) {
      return;
    }

    savedPosition = clampPosition(position);
    root.style.left = `${Math.round(savedPosition.x)}px`;
    root.style.top = `${Math.round(savedPosition.y)}px`;
    root.style.right = "auto";
    root.style.bottom = "auto";

    if (persist) {
      storageSet({ hazakuraAmpPosition: savedPosition });
    }
  }

  function setStatus(message) {
    if (statusText) {
      statusText.textContent = message;
    }
  }

  function setBoostPercent(percent) {
    const clamped = Math.max(0, Math.min(400, Number(percent) || 0));
    boostInput.value = String(clamped);
    boostValue.textContent = `${Math.round(clamped)}%`;
    updateBoostSafety(clamped);
    presetButtons.forEach((button) => {
      const preset = Number(button.dataset.boostPreset);
      button.classList.toggle("is-active", preset === Math.round(clamped));
      button.setAttribute("aria-pressed", String(preset === Math.round(clamped)));
    });
    return clamped;
  }

  function updateBoostSafety(percent) {
    if (!root || !boostSafetyText) {
      return;
    }
    const isHighBoost = percent >= 300;
    root.classList.toggle("hazakura-amp-high-boost", isHighBoost);
    boostSafetyText.textContent = isHighBoost ? "High boost may clip loud sources." : "";
  }

  function stateUpdatedAtMs(state) {
    if (typeof state?.updatedAt !== "number" || !Number.isFinite(state.updatedAt)) {
      return null;
    }
    return state.updatedAt * 1000;
  }

  function isFreshState(state) {
    const updatedAt = stateUpdatedAtMs(state);
    return updatedAt !== null && Date.now() - updatedAt <= staleStateThresholdMs;
  }

  function markConnection(isConnected, message) {
    if (!root) {
      return;
    }
    root.classList.toggle("hazakura-amp-disconnected", !isConnected);
    if (!isConnected) {
      setStatus(message || "App disconnected");
    }
  }

  function applyRemoteState(state) {
    if (!state || !root || !boostInput) {
      return;
    }
    if (typeof state.configuredGain === "number") {
      setBoostPercent(state.configuredGain * 100);
    }
    if (!isFreshState(state)) {
      markConnection(false, "App disconnected");
      return;
    }
    markConnection(true);
    setStatus(state.statusText || (state.isRunning ? "running" : "idle"));
  }

  function applyCollapsed() {
    root.classList.toggle("hazakura-amp-collapsed", collapsed);
    collapseButton.setAttribute("aria-expanded", String(!collapsed));
    collapseButton.textContent = collapsed ? "+" : "−";
    requestAnimationFrame(() => {
      if (isPosition(savedPosition)) {
        applyPosition(savedPosition, true);
      }
    });
  }

  function applyRepeat() {
    const video = document.querySelector("video");
    if (video) {
      video.loop = repeatEnabled;
    }
    repeatButton.setAttribute("aria-pressed", String(repeatEnabled));
    repeatButton.classList.toggle("is-on", repeatEnabled);
  }

  function sendCommand(command) {
    return runtimeSend(command).then((response) => {
      if (!response?.ok) {
        markConnection(false, response?.error || "App disconnected");
        return null;
      }
      return response.reply;
    }).catch((error) => {
      markConnection(false, error?.message || "App disconnected");
      return null;
    });
  }

  function requestState() {
    return sendCommand({ kind: "requestState" }).then((state) => {
      applyRemoteState(state);
    });
  }

  function sendGainPercent(percent) {
    const clamped = setBoostPercent(percent);
    const gain = clamped / 100;
    clearTimeout(sendTimer);
    sendTimer = setTimeout(() => {
      sendCommand({ kind: "setGain", gain })
        .then(() => sendCommand({ kind: "requestStart" }))
        .then((state) => applyRemoteState(state))
        .then(() => requestState());
    }, 120);
  }

  function sendGainFromInput() {
    sendGainPercent(boostInput.value);
  }

  function makeButton(label, className) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = className;
    button.textContent = label;
    return button;
  }

  function startDrag(event) {
    if (event.button !== 0 || event.target === collapseButton) {
      return;
    }

    const rect = root.getBoundingClientRect();
    dragState = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      rootX: rect.left,
      rootY: rect.top
    };
    root.classList.add("hazakura-amp-dragging");
    header.setPointerCapture(event.pointerId);
    event.preventDefault();
  }

  function moveDrag(event) {
    if (!dragState || event.pointerId !== dragState.pointerId) {
      return;
    }
    applyPosition({
      x: dragState.rootX + event.clientX - dragState.startX,
      y: dragState.rootY + event.clientY - dragState.startY
    });
  }

  function endDrag(event) {
    if (!dragState || event.pointerId !== dragState.pointerId) {
      return;
    }
    if (header.hasPointerCapture?.(event.pointerId)) {
      header.releasePointerCapture(event.pointerId);
    }
    root.classList.remove("hazakura-amp-dragging");
    if (isPosition(savedPosition)) {
      storageSet({ hazakuraAmpPosition: savedPosition });
    }
    dragState = null;
  }

  function createBar() {
    root = document.createElement("section");
    root.id = rootId;
    root.className = "hazakura-amp-floating-bar";
    root.setAttribute("aria-label", "Hazakura Amp YouTube remote");

    header = document.createElement("div");
    header.className = "hazakura-amp-header";
    header.addEventListener("pointerdown", startDrag);
    header.addEventListener("pointermove", moveDrag);
    header.addEventListener("pointerup", endDrag);
    header.addEventListener("pointercancel", endDrag);

    const title = document.createElement("span");
    title.className = "hazakura-amp-title";
    title.textContent = "Hazakura Amp";

    collapseButton = makeButton("−", "hazakura-amp-icon-button");
    collapseButton.setAttribute("aria-label", "Collapse Hazakura Amp remote");
    collapseButton.addEventListener("click", () => {
      collapsed = !collapsed;
      storageSet({ hazakuraAmpCollapsed: collapsed });
      applyCollapsed();
    });

    header.append(title, collapseButton);

    const controls = document.createElement("div");
    controls.className = "hazakura-amp-controls";

    const boostRow = document.createElement("label");
    boostRow.className = "hazakura-amp-boost-row";

    const boostLabel = document.createElement("span");
    boostLabel.textContent = "Boost";

    boostInput = document.createElement("input");
    boostInput.type = "range";
    boostInput.min = "0";
    boostInput.max = "400";
    boostInput.step = "5";
    boostInput.value = "100";
    boostInput.setAttribute("aria-label", "Hazakura Amp boost");
    boostInput.addEventListener("input", sendGainFromInput);

    boostValue = document.createElement("output");
    boostValue.className = "hazakura-amp-boost-value";
    boostValue.textContent = "100%";

    boostRow.append(boostLabel, boostInput, boostValue);

    const presetRow = document.createElement("div");
    presetRow.className = "hazakura-amp-preset-row";
    presetButtons = boostPresets.map((preset) => {
      const button = makeButton(String(preset), "hazakura-amp-preset-button");
      button.dataset.boostPreset = String(preset);
      button.setAttribute("aria-label", `Set Hazakura Amp boost to ${preset}%`);
      button.setAttribute("aria-pressed", "false");
      button.addEventListener("click", () => sendGainPercent(preset));
      return button;
    });
    presetRow.append(...presetButtons);

    boostSafetyText = document.createElement("div");
    boostSafetyText.className = "hazakura-amp-safety";
    boostSafetyText.setAttribute("aria-live", "polite");

    const actionRow = document.createElement("div");
    actionRow.className = "hazakura-amp-action-row";

    repeatButton = makeButton("Repeat", "hazakura-amp-repeat-button");
    repeatButton.setAttribute("aria-pressed", "false");
    repeatButton.addEventListener("click", () => {
      repeatEnabled = !repeatEnabled;
      storageSet({ hazakuraAmpRepeatEnabled: repeatEnabled });
      applyRepeat();
    });

    statusText = document.createElement("span");
    statusText.className = "hazakura-amp-status";
    statusText.textContent = "idle";

    actionRow.append(repeatButton, statusText);
    controls.append(boostRow, presetRow, boostSafetyText, actionRow);
    root.append(header, controls);
    document.documentElement.append(root);
  }

  function ensureBar() {
    if (!isWatchPage()) {
      root?.remove();
      root = undefined;
      return;
    }

    if (!document.getElementById(rootId)) {
      createBar();
      if (isPosition(savedPosition)) {
        requestAnimationFrame(() => applyPosition(savedPosition));
      }
      applyCollapsed();
      applyRepeat();
      requestState();
    }
  }

  function handleNavigation() {
    if (location.href === lastUrl) {
      return;
    }
    lastUrl = location.href;
    setTimeout(() => {
      ensureBar();
      applyRepeat();
      requestState();
    }, 200);
  }

  storageGet(storageDefaults).then((values) => {
    collapsed = Boolean(values.hazakuraAmpCollapsed);
    repeatEnabled = Boolean(values.hazakuraAmpRepeatEnabled);
    savedPosition = isPosition(values.hazakuraAmpPosition) ? values.hazakuraAmpPosition : null;
    ensureBar();
  });

  document.addEventListener("yt-navigate-finish", handleNavigation);
  document.addEventListener("loadedmetadata", applyRepeat, true);
  window.addEventListener("resize", () => {
    if (isPosition(savedPosition)) {
      applyPosition(savedPosition, true);
    }
  });
  setInterval(handleNavigation, 1000);
  setInterval(() => {
    if (root && isWatchPage()) {
      requestState();
    }
  }, statePollIntervalMs);
})();
