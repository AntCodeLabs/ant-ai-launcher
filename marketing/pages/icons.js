// SHRIMP and ANT (SVG path data) come from marks.js, generated from the app's own drawing code.
const I = {
 folder:'<svg viewBox="0 0 16 16"><path d="M1.5 4.5v8a1 1 0 0 0 1 1h11a1 1 0 0 0 1-1v-6.5a1 1 0 0 0-1-1H8L6.5 3h-4a1 1 0 0 0-1 1.5z"/></svg>',
 terminal:'<svg viewBox="0 0 16 16"><rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="M4.5 6.5l2 1.5-2 1.5M8 10h3.5"/></svg>',
 cloud:'<svg viewBox="0 0 16 16"><path d="M4.5 12.5h7.2a2.8 2.8 0 0 0 .3-5.6A4 4 0 0 0 4.3 6.6a3 3 0 0 0 .2 5.9z"/></svg>',
 plus:'<svg viewBox="0 0 16 16"><path d="M1.5 4.5v8a1 1 0 0 0 1 1h11a1 1 0 0 0 1-1v-6.5a1 1 0 0 0-1-1H8L6.5 3h-4a1 1 0 0 0-1 1.5z"/><path d="M8 7.5v4M6 9.5h4"/></svg>',
 clock:'<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6"/><path d="M8 4.5V8l2.5 1.5"/></svg>',
 bubble:'<svg viewBox="0 0 16 16"><path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z"/><path d="M5 6.5h6M5 8.5h4"/></svg>',
 bookmark:'<svg viewBox="0 0 16 16"><path d="M4.5 2.5h7v11l-3.5-2.5-3.5 2.5z"/></svg>',
 sunrise:'<svg viewBox="0 0 16 16"><path d="M3.5 11a4.5 4.5 0 0 1 9 0M1.5 13.5h13M8 2.5v3M3.3 5.3l1.4 1.4M12.7 5.3l-1.4 1.4"/></svg>',
 more:'<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6"/><path d="M5 8h.01M8 8h.01M11 8h.01" stroke-width="2.2"/></svg>',
 needs:'<svg viewBox="0 0 16 16"><path d="M2.5 3h11v7.5h-6l-3 2.5v-2.5h-2z" fill="#ff9500" stroke="#ff9500"/><path d="M8 4.8v2.6M8 9h.01" stroke="#fff" stroke-width="1.6"/></svg>',
 done:'<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6.5" fill="#34c759" stroke="#34c759"/><path d="M5 8.2l2 2 4-4.2" stroke="#fff" stroke-width="1.7"/></svg>',
 working:'<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6.2" stroke="#0a7aff" stroke-dasharray="2 2.2"/><circle cx="8" cy="8" r="2.6" fill="#0a7aff" stroke="#0a7aff"/></svg>',
 idle:'<svg viewBox="0 0 16 16"><path d="M10.5 3a5 5 0 1 0 3 8.4A5.5 5.5 0 0 1 10.5 3z" stroke="#aeaeb2"/></svg>',
 person:'<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6.5"/><circle cx="8" cy="6.5" r="2.2"/><path d="M4 12.3a4.6 4.6 0 0 1 8 0"/></svg>',
 gear:'<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="2.3"/><path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M3.4 12.6l1.4-1.4M11.2 4.8l1.4-1.4"/></svg>',
 dotOn:'<span class="dot" style="background:#34c759"></span>',
};
function glyph(cls){ return '<svg class="'+(cls||'glyph')+'" viewBox="0 0 32 32"><path d="'+SHRIMP+'"/></svg>'; }
function antsvg(){ return '<svg viewBox="0 0 32 32"><path d="'+ANT+'"/></svg>'; }
