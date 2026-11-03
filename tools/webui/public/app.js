(() => {
  "use strict";

  const token = new URLSearchParams(window.location.search).get("token") || "";
  const $ = (id) => document.getElementById(id);
  let activeJob = null;
  let activeTimer = null;

  async function api(path, options = {}) {
    const headers = Object.assign(
      { "X-WebUI-Token": token },
      options.headers || {}
    );
    if (options.body) headers["Content-Type"] = "application/json";
    const response = await fetch(path, Object.assign({}, options, { headers }));
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
    return data;
  }

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function renderProfiles(state) {
    const box = $("profiles");
    const error = $("profiles-error");
    box.replaceChildren();
    error.textContent = state.error || "";
    $("root").textContent = state.root || "";
    if (!state.profiles || state.profiles.length === 0) {
      box.append(el("p", "muted", "还没有 profile。先在下方创建一个，或用浏览器打开现有实例。"));
      return;
    }
    for (const profile of state.profiles) {
      const card = el("article", "card");
      const title = el("h3", "", profile.name || profile.id);
      title.title = profile.id;
      card.append(title);
      const meta = el("div", "meta");
      meta.append(el("span", "", `version: ${profile.version || "?"}`));
      meta.append(el("span", "", `game: ${profile.game_dir || "?"}`));
      if (profile.external) meta.append(el("span", "badge", "external"));
      card.append(meta);

      const actions = el("div", "actions");
      const download = el("button", "", "Download");
      const launch = el("button", "primary", "Launch");
      download.addEventListener("click", () => startAction("download", profile.id, download));
      launch.addEventListener("click", () => startAction("launch", profile.id, launch));
      actions.append(download, launch);
      card.append(actions);
      box.append(card);
    }
  }

  async function loadState() {
    try {
      renderProfiles(await api("/api/state"));
    } catch (err) {
      $("profiles-error").textContent = err.message;
    }
  }

  async function pollJob(jobId, label) {
    if (activeTimer) clearInterval(activeTimer);
    activeJob = jobId;
    $("job-status").textContent = `${label} · running`;
    activeTimer = setInterval(async () => {
      try {
        const job = await api(`/api/jobs/${encodeURIComponent(jobId)}`);
        $("job-output").textContent = (job.output || []).join("\n") || "(no output)";
        $("job-status").textContent = `${label} · ${job.status} · ${job.elapsed}s`;
        if (job.status !== "running") {
          clearInterval(activeTimer);
          activeTimer = null;
          document.querySelectorAll("button").forEach((b) => (b.disabled = false));
          if (job.status === "done") $("job-status").classList.add("ok");
          loadState();
        }
      } catch (err) {
        $("job-status").textContent = `${label} · ${err.message}`;
      }
    }, 1000);
  }

  async function startAction(action, profileId, button) {
    document.querySelectorAll("button").forEach((b) => (b.disabled = true));
    $("job-output").textContent = `starting ${action} ${profileId} ...`;
    try {
      const data = await api("/api/action", {
        method: "POST",
        body: JSON.stringify({ action, profile: profileId }),
      });
      pollJob(data.job, `${action} ${profileId}`);
    } catch (err) {
      $("job-status").textContent = err.message;
      $("job-output").textContent = err.message;
      document.querySelectorAll("button").forEach((b) => (b.disabled = false));
    }
  }

  async function checkJava() {
    $("java-output").textContent = "探测中...";
    try {
      const data = await api("/api/java");
      pollJavaJob(data.job);
    } catch (err) {
      $("java-output").textContent = err.message;
    }
  }

  async function pollJavaJob(jobId) {
    try {
      const job = await api(`/api/jobs/${encodeURIComponent(jobId)}`);
      $("java-output").textContent = (job.output || []).join("\n") || "(no output)";
      if (job.status === "running") setTimeout(() => pollJavaJob(jobId), 800);
      else if (job.status === "failed") $("java-output").textContent += "\n(failed)";
    } catch (err) {
      $("java-output").textContent = err.message;
    }
  }

  $("refresh").addEventListener("click", loadState);
  $("java").addEventListener("click", checkJava);

  $("create").addEventListener("submit", async (event) => {
    event.preventDefault();
    const version = $("version").value.trim();
    const name = $("name").value.trim();
    $("job-output").textContent = `creating ${version} ...`;
    try {
      const data = await api("/api/profile", {
        method: "POST",
        body: JSON.stringify({ version, name }),
      });
      pollJob(data.job, "profile create");
    } catch (err) {
      $("job-output").textContent = err.message;
    }
  });

  if (!token) {
    $("profiles-error").textContent = "URL 缺少 token，请从 server.py 输出的地址打开。";
  } else {
    loadState();
  }
})();
