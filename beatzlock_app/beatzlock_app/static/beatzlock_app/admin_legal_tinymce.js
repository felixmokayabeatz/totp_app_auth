(function () {
  function initLegalEditor() {
    if (!window.tinymce) {
      return;
    }

    window.tinymce.init({
      selector: 'textarea.beatzlock-legal-tinymce',
      license_key: 'gpl',
      height: 460,
      menubar: 'file edit view insert format tools table help',
      plugins: [
        'advlist', 'autolink', 'lists', 'link', 'charmap', 'preview', 'anchor',
        'searchreplace', 'visualblocks', 'code', 'fullscreen', 'insertdatetime',
        'table', 'help', 'wordcount'
      ].join(' '),
      toolbar: [
        'undo redo | blocks | bold italic underline strikethrough |',
        'forecolor backcolor | alignleft aligncenter alignright alignjustify |',
        'bullist numlist outdent indent | link table | removeformat code fullscreen'
      ].join(' '),
      branding: false,
      promotion: false,
      convert_urls: false,
      browser_spellcheck: true,
      contextmenu: false,
      skin: 'oxide-dark',
      content_css: 'dark',
      content_style: [
        'body { font-family: Inter, Arial, sans-serif; font-size: 15px; line-height: 1.7; }',
        'a { color: #38bdf8; }',
        'table { width: 100%; border-collapse: collapse; }',
        'td, th { border: 1px solid #475569; padding: 8px 10px; }',
        'blockquote { border-left: 4px solid #38bdf8; margin-left: 0; padding-left: 14px; color: #cbd5e1; }'
      ].join(' '),
      setup: function (editor) {
        editor.on('change keyup', function () {
          editor.save();
        });
      }
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initLegalEditor);
  } else {
    initLegalEditor();
  }
})();
