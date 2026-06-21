const runtimeApi = globalThis.browser ?? globalThis.chrome;
const nativeAppName = "dev.keisetsu.hazakura-amp";

function sendNativeMessage(message) {
  if (!runtimeApi?.runtime?.sendNativeMessage) {
    return Promise.reject(new Error("Native messaging is unavailable."));
  }

  const response = runtimeApi.runtime.sendNativeMessage(nativeAppName, message);
  if (response && typeof response.then === "function") {
    return response;
  }

  return new Promise((resolve, reject) => {
    runtimeApi.runtime.sendNativeMessage(nativeAppName, message, (reply) => {
      const error = runtimeApi.runtime.lastError;
      if (error) {
        reject(new Error(error.message));
        return;
      }
      resolve(reply);
    });
  });
}

runtimeApi.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.target !== "hazakuraAmp") {
    return false;
  }

  sendNativeMessage(message.payload)
    .then((reply) => {
      if (reply?.ok === false) {
        sendResponse({ ok: false, error: reply.error || "Hazakura Amp is not ready" });
        return;
      }
      sendResponse({ ok: true, reply });
    })
    .catch((error) => sendResponse({ ok: false, error: error.message }));
  return true;
});
