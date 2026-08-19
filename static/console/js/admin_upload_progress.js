(function () {
  function onReady(callback) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", callback);
      return;
    }
    callback();
  }

  function formatBytes(bytes) {
    if (!bytes) {
      return "0 B";
    }

    var units = ["B", "KB", "MB", "GB", "TB"];
    var unitIndex = 0;
    var size = bytes;

    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex += 1;
    }

    var precision = size >= 10 || unitIndex === 0 ? 0 : 1;
    return size.toFixed(precision) + " " + units[unitIndex];
  }

  function getSelectedFileInputs(form) {
    return Array.prototype.filter.call(
      form.querySelectorAll('input[type="file"]'),
      function (input) {
        return !input.disabled && input.files && input.files.length > 0;
      }
    );
  }

  function buildStatusMessage(fileInputs) {
    var names = [];
    var totalBytes = 0;

    fileInputs.forEach(function (input) {
      Array.prototype.forEach.call(input.files, function (file) {
        names.push(file.name);
        totalBytes += file.size || 0;
      });
    });

    var fileCount = names.length;
    var previewNames = names.slice(0, 2).join(", ");
    var suffix = fileCount > 2 ? " +" + (fileCount - 2) + " more" : "";

    return {
      fileCount: fileCount,
      totalBytes: totalBytes,
      summary:
        "Uploading " +
        fileCount +
        " file" +
        (fileCount === 1 ? "" : "s") +
        (previewNames ? ": " + previewNames + suffix : "") +
        (totalBytes ? " (" + formatBytes(totalBytes) + ")" : ""),
    };
  }

  function getOrCreateProgressPanel(form) {
    var panel = form.querySelector(".fmb-admin-upload-progress");
    if (panel) {
      return panel;
    }

    panel = document.createElement("section");
    panel.className = "fmb-admin-upload-progress";
    panel.hidden = true;
    panel.innerHTML =
      '<div class="fmb-admin-upload-progress__head">' +
      '<span class="fmb-admin-upload-progress__title">Upload progress</span>' +
      '<span class="fmb-admin-upload-progress__percent" aria-live="polite">0%</span>' +
      "</div>" +
      '<div class="fmb-admin-upload-progress__bar" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0">' +
      '<span class="fmb-admin-upload-progress__fill"></span>' +
      "</div>" +
      '<p class="fmb-admin-upload-progress__status">Preparing upload...</p>';

    var submitRow = form.querySelector(".submit-row");
    if (submitRow && submitRow.parentNode) {
      submitRow.parentNode.insertBefore(panel, submitRow);
      return panel;
    }

    var firstChild = form.firstElementChild;
    if (firstChild && firstChild.parentNode) {
      firstChild.parentNode.insertBefore(panel, firstChild);
      return panel;
    }

    form.appendChild(panel);
    return panel;
  }

  function updateProgressPanel(panel, percent, status, isIndeterminate) {
    var safePercent = Math.max(0, Math.min(100, percent || 0));
    var fill = panel.querySelector(".fmb-admin-upload-progress__fill");
    var percentLabel = panel.querySelector(".fmb-admin-upload-progress__percent");
    var statusLabel = panel.querySelector(".fmb-admin-upload-progress__status");
    var bar = panel.querySelector(".fmb-admin-upload-progress__bar");

    panel.hidden = false;
    panel.classList.toggle("is-indeterminate", Boolean(isIndeterminate));

    if (!isIndeterminate) {
      fill.style.width = safePercent + "%";
    } else {
      fill.style.width = "";
    }

    percentLabel.textContent = isIndeterminate ? "..." : safePercent + "%";
    statusLabel.textContent = status;
    bar.setAttribute("aria-valuenow", String(safePercent));
  }

  function setSubmittingState(form, isSubmitting) {
    form.classList.toggle("fmb-admin-is-uploading", isSubmitting);
    form.dataset.fmbUploading = isSubmitting ? "true" : "false";

    Array.prototype.forEach.call(
      form.querySelectorAll('input[type="submit"], button[type="submit"]'),
      function (button) {
        button.disabled = isSubmitting;
      }
    );
  }

  function replaceDocumentWithResponse(markup) {
    if (!markup) {
      window.location.reload();
      return;
    }

    document.open();
    document.write(markup);
    document.close();
  }

  function bindUploadProgress(form) {
    if (form.dataset.fmbUploadBound === "true") {
      return;
    }
    form.dataset.fmbUploadBound = "true";

    form.addEventListener("submit", function (event) {
      var fileInputs = getSelectedFileInputs(form);
      if (!fileInputs.length || typeof XMLHttpRequest === "undefined" || typeof FormData === "undefined") {
        return;
      }

      if (form.dataset.fmbUploading === "true") {
        event.preventDefault();
        return;
      }

      event.preventDefault();

      var uploadMeta = buildStatusMessage(fileInputs);
      var panel = getOrCreateProgressPanel(form);
      var submitter = event.submitter || null;
      var formData;

      try {
        formData = submitter ? new FormData(form, submitter) : new FormData(form);
      } catch (error) {
        formData = new FormData(form);
        if (submitter && submitter.name) {
          formData.append(submitter.name, submitter.value);
        }
      }

      updateProgressPanel(panel, 0, uploadMeta.summary, false);
      setSubmittingState(form, true);

      var xhr = new XMLHttpRequest();
      xhr.open((form.getAttribute("method") || "POST").toUpperCase(), form.getAttribute("action") || window.location.href, true);

      xhr.upload.addEventListener("progress", function (progressEvent) {
        if (!progressEvent.lengthComputable) {
          updateProgressPanel(panel, 0, uploadMeta.summary, true);
          return;
        }

        var percent = Math.round((progressEvent.loaded / progressEvent.total) * 100);
        updateProgressPanel(
          panel,
          percent,
          uploadMeta.summary + " - " + formatBytes(progressEvent.loaded) + " of " + formatBytes(progressEvent.total),
          false
        );
      });

      xhr.upload.addEventListener("load", function () {
        updateProgressPanel(panel, 100, "Upload finished. Saving the admin record...", false);
      });

      xhr.addEventListener("load", function () {
        setSubmittingState(form, false);

        if (xhr.status >= 200 && xhr.status < 400) {
          replaceDocumentWithResponse(xhr.responseText);
          return;
        }

        updateProgressPanel(panel, 0, "The upload could not be completed. Please try again.", false);
      });

      xhr.addEventListener("error", function () {
        setSubmittingState(form, false);
        updateProgressPanel(panel, 0, "The upload failed before the server finished responding.", false);
      });

      xhr.addEventListener("abort", function () {
        setSubmittingState(form, false);
        updateProgressPanel(panel, 0, "The upload was canceled.", false);
      });

      xhr.send(formData);
    });
  }

  onReady(function () {
    if (!document.body.classList.contains("change-form")) {
      return;
    }

    Array.prototype.forEach.call(
      document.querySelectorAll('form[enctype="multipart/form-data"]'),
      bindUploadProgress
    );
  });
})();
