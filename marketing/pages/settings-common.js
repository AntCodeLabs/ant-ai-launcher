function sidebar(sel){
  const row=(ic,t,s)=>`<div class="srow ${s?'sel':''}">${I[ic]}${t}</div>`;
  return `<div class="side"><h6>Logins</h6>${row('person','Personal',sel==='Personal')}${row('person','Work',sel==='Work')}
   <div style="height:10px"></div>${row('gear','General')}
   <div class="foot"><div class="antbox">${antsvg()}</div><div><b>Made by AntCodeLabs</b><small>antcodelabs.ai</small></div></div></div>`;
}
function windowShell(inner, sel, style){
  return `<div class="win" style="${style}"><div class="titlebar"><div class="lights"><i style="background:#ff5f57"></i><i style="background:#febc2e"></i><i style="background:#28c840"></i></div>Clauncher</div>
   <div class="body">${sidebar(sel)}<div class="detail">${inner}</div></div></div>`;
}
