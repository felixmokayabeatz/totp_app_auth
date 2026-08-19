(function () {
  var themeKey = "felixmokayabeatz-theme";
  var root = document.documentElement;
  var activePreview = null;
  var activePreviewButton = null;
  var previewPlayCountTimers = {};

  // Count a beat play once a preview has been listened to for a few seconds,
  // regardless of which page the preview lives on (purchased library, cart,
  // checkout success, etc). Mirrors the explore-page behaviour.
  function scheduleBeatPlayCount(audio, button) {
    var beatId = (button && button.dataset.beatId) || (audio && audio.dataset.beatId);
    if (!beatId || (audio && audio.dataset.playCounted === "true")) return;

    clearTimeout(previewPlayCountTimers[beatId]);
    previewPlayCountTimers[beatId] = setTimeout(function () {
      if (!audio || audio.paused) return;
      audio.dataset.playCounted = "true";
      fetch("/beat/" + beatId + "/increment_play_count/")
        .then(function (response) { return response.json(); })
        .then(function (data) {
          if (!data || data.play_count === undefined) return;
          var countEl = document.getElementById("play-count-" + beatId) ||
            document.querySelector('[data-beat-play-count="' + beatId + '"]');
          if (countEl) countEl.textContent = Number(data.play_count).toLocaleString();
        })
        .catch(function () {});
    }, 5000);
  }

  function cancelBeatPlayCount(audio, button) {
    var beatId = (button && button.dataset.beatId) || (audio && audio.dataset.beatId);
    if (!beatId) return;
    clearTimeout(previewPlayCountTimers[beatId]);
  }

  function safeGetTheme() {
    try {
      var stored = localStorage.getItem(themeKey);
      if (stored === "light" || stored === "dark") return stored;
    } catch (error) {
      return root.dataset.fmbTheme || "dark";
    }
    return root.dataset.fmbTheme || "dark";
  }

  function setTheme(theme) {
    root.dataset.fmbTheme = theme;
    try {
      localStorage.setItem(themeKey, theme);
    } catch (error) {
      return;
    }
  }

  function updateThemeButtons() {
    var isLight = root.dataset.fmbTheme === "light";
    document.querySelectorAll("[data-fmb-theme-toggle]").forEach(function (button) {
      var label = isLight ? "Dark" : "Light";
      button.setAttribute("aria-label", "Switch to " + label.toLowerCase() + " theme");
      button.setAttribute("title", "Switch to " + label.toLowerCase() + " theme");
      button.innerHTML = '<i class="fas ' + (isLight ? "fa-moon" : "fa-sun") + '" aria-hidden="true"></i><span>' + label + "</span>";
    });
  }

  function bindTheme() {
    setTheme(safeGetTheme());
    updateThemeButtons();

    document.querySelectorAll("[data-fmb-theme-toggle]").forEach(function (button) {
      if (button.dataset.fmbBound === "true") return;
      button.dataset.fmbBound = "true";
      button.addEventListener("click", function () {
        setTheme(root.dataset.fmbTheme === "light" ? "dark" : "light");
        updateThemeButtons();
      });
    });
  }

  function bindMobileNav() {
    var toggle = document.querySelector("[data-fmb-menu-toggle]");
    var panel = document.getElementById("fmbMobileNav");
    if (!toggle || !panel) return;

    toggle.addEventListener("click", function () {
      var next = !panel.classList.contains("is-open");
      panel.classList.toggle("is-open", next);
      toggle.setAttribute("aria-expanded", String(next));
    });

    panel.querySelectorAll("a").forEach(function (link) {
      link.addEventListener("click", function () {
        panel.classList.remove("is-open");
        toggle.setAttribute("aria-expanded", "false");
      });
    });
  }

  function setPreviewButton(button, state) {
    if (!button) return;

    var states = {
      stopped: {
        icon: "fa-play",
        text: button.dataset.previewLabel || "Play",
        label: "Play beat preview",
      },
      loading: {
        icon: "fa-spinner fa-spin",
        text: "Loading",
        label: "Loading beat preview",
      },
      playing: {
        icon: "fa-pause",
        text: "Pause",
        label: "Pause beat preview",
      },
      paused: {
        icon: "fa-play",
        text: "Resume",
        label: "Resume beat preview",
      },
      ended: {
        icon: "fa-rotate-right",
        text: "Replay",
        label: "Replay beat preview",
      },
    };
    var next = states[state] || states.stopped;
    button.dataset.previewState = state;
    button.setAttribute("aria-label", next.label);
    button.innerHTML = '<i class="fas ' + next.icon + '" aria-hidden="true"></i><span>' + next.text + "</span>";
  }

  function stopActivePreview() {
    if (activePreview) {
      activePreview.pause();
    }
    if (activePreviewButton) {
      setPreviewButton(activePreviewButton, activePreview && activePreview.currentTime > 0 ? "paused" : "stopped");
    }
    activePreview = null;
    activePreviewButton = null;
  }

  function bindInlinePreviews() {
    document.querySelectorAll("[data-fmb-preview]").forEach(function (button) {
      if (button.dataset.fmbPreviewBound === "true") return;
      button.dataset.fmbPreviewBound = "true";
      setPreviewButton(button, "stopped");

      button.addEventListener("click", function () {
        var audio = document.getElementById(button.dataset.audioId);
        if (!audio) return;

        if (activePreview && activePreview !== audio) {
          stopActivePreview();
        }

        if (!audio.paused) {
          audio.pause();
          setPreviewButton(button, audio.currentTime > 0 ? "paused" : "stopped");
          cancelBeatPlayCount(audio, button);
          activePreview = null;
          activePreviewButton = null;
          return;
        }

        activePreview = audio;
        activePreviewButton = button;
        setPreviewButton(button, "loading");
        audio.preload = "auto";

        audio.play().then(function () {
          setPreviewButton(button, "playing");
          scheduleBeatPlayCount(audio, button);
        }).catch(function () {
          setPreviewButton(button, audio.currentTime > 0 ? "paused" : "stopped");
        });
      });
    });

    document.querySelectorAll("audio[data-fmb-preview-audio]").forEach(function (audio) {
      if (audio.dataset.fmbAudioBound === "true") return;
      audio.dataset.fmbAudioBound = "true";

      audio.addEventListener("ended", function () {
        var button = document.querySelector('[data-fmb-preview][data-audio-id="' + audio.id + '"]');
        setPreviewButton(button, "ended");
        cancelBeatPlayCount(audio, button);
        audio.dataset.playCounted = "";
        if (activePreview === audio) {
          activePreview = null;
          activePreviewButton = null;
        }
      });

      audio.addEventListener("pause", function () {
        if (audio.ended) return;
        var button = document.querySelector('[data-fmb-preview][data-audio-id="' + audio.id + '"]');
        cancelBeatPlayCount(audio, button);
        if (button && activePreview === audio) {
          setPreviewButton(button, audio.currentTime > 0 ? "paused" : "stopped");
        }
      });
    });
  }

  function bindFlashToasts() {
    var flashMessages = Array.from(document.querySelectorAll(".fmb-flash[data-fmb-toast-trigger]"));
    if (!flashMessages.length) return;

    var flashWrap = flashMessages[0].closest(".fmb-flash-wrap");
    var stack = document.querySelector("[data-fmb-toast-stack]");
    if (!stack) {
      stack = document.createElement("div");
      stack.className = "fmb-toast-stack";
      stack.setAttribute("data-fmb-toast-stack", "");
      document.body.appendChild(stack);
    }

    var queue = flashMessages.map(function (flash) {
      var toast = document.createElement("div");
      toast.className = "fmb-toast-item";

      var tone = "info";
      if (flash.className.indexOf("error") !== -1) {
        tone = "error";
      } else if (flash.className.indexOf("warning") !== -1) {
        tone = "warning";
      } else if (flash.className.indexOf("success") !== -1) {
        tone = "success";
      }

      toast.dataset.tone = tone;
      toast.textContent = (flash.textContent || "").trim();
      return toast;
    });

    flashMessages.forEach(function (flash) {
      flash.remove();
    });
    if (flashWrap && !flashWrap.children.length) {
      flashWrap.remove();
    }

    function showNextToast() {
      if (!queue.length) return;

      var toast = queue.shift();
      stack.appendChild(toast);
      requestAnimationFrame(function () {
        toast.classList.add("is-visible");
      });

      window.setTimeout(function () {
        toast.classList.remove("is-visible");
        window.setTimeout(function () {
          toast.remove();
          showNextToast();
        }, 220);
      }, 2800);
    }

    showNextToast();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () {
      bindTheme();
      bindMobileNav();
      bindInlinePreviews();
      bindFlashToasts();
    });
  } else {
    bindTheme();
    bindMobileNav();
    bindInlinePreviews();
    bindFlashToasts();
  }
})();
