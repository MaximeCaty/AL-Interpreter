try {
    Startup();
} catch (e) {
    var root = document.getElementById('controlAddIn');
    if (root) {
        root.style.color = '#ff6b6b';
        root.style.fontFamily = 'monospace';
        root.style.whiteSpace = 'pre-wrap';
        root.textContent = 'ALI Code Editor startup failed: ' + (e && e.message ? e.message : e);
    }
}
