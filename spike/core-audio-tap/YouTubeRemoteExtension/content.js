(() => {
  const runtimeApi = globalThis.browser ?? globalThis.chrome;
  const rootId = "hazakura-amp-floating-bar";
  const storageDefaults = {
    hazakuraAmpCollapsed: false,
    hazakuraAmpRepeatEnabled: false
  };

  let root;
  let boostInput;
  let boostValue;
  let statusText;
  let repeatButton;
  let collapseButton;
  let repeatEnabled = false;
  let collapsed = false;
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

  function setStatus(message) {
    if (statusText) {
      statusText.textContent = message;
    }
  }

  function setBoostPercent(percent) {
    const clamped = Math.max(0, Math.min(400, Number(percent) || 0));
    boostInput.value = String(clamped);
    boostValue.textContent = `${Math.round(clamped)}%`;
  }

  function applyCollapsed() {
    root.classList.toggle("hazakura-amp-collapsed", collapsed);
    collapseButton.setAttribute("aria-expanded", String(!collapsed));
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
        setStatus(response?.error || "Hazakura Amp unavailable");
        return null;
      }
      return response.reply;
    });
  }

  function requestState() {
    return sendCommand({ kind: "requestState" }).then((state) => {
      if (!state) {
        return;
      }
      if (typeof state.configuredGain === "number") {
        setBoostPercent(state.configuredGain * 100);
      }
      setStatus(state.statusText || (state.isRunning ? "running" : "idle"));
    });
  }

  function sendGainFromInput() {
    const gain = Number(boostInput.value) / 100;
    setBoostPercent(boostInput.value);
    clearTimeout(sendTimer);
    sendTimer = setTimeout(() => {
      sendCommand({ kind: "setGain", gain })
        .then(() => sendCommand({ kind: "requestStart" }))
        .then(() => requestState());
    }, 120);
  }

  function makeButton(label, className) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = className;
    button.textContent = label;
    return button;
  }

  function createBar() {
    root = document.createElement("section");
    root.id = rootId;
    root.className = "hazakura-amp-floating-bar";
    root.setAttribute("aria-label", "Hazakura Amp YouTube remote");

    const header = document.createElement("div");
    header.className = "hazakura-amp-header";

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
    controls.append(boostRow, actionRow);
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
    ensureBar();
  });

  document.addEventListener("yt-navigate-finish", handleNavigation);
  document.addEventListener("loadedmetadata", applyRepeat, true);
  setInterval(handleNavigation, 1000);
})();
