// Reads the page atomically: every visible control, its accessible name and
// value, the visible text, and the guards that say whether any of it has moved
// since. Node identity is kept in a WeakMap so a decision refers to an element
// Rail observed rather than to a selector anyone generated.
//
// Adapted from jev-ultrafast (https://github.com/browser-use/jev-ultrafast),
// MIT, Copyright (c) 2026 Browser Use.
(() => {
  if (!document.body) return null;
  const cache = window.__railQa ||= {ids:new WeakMap(), nodes:new Map(), next:1};
  const identity = e => {
    if (!cache.ids.has(e)) cache.ids.set(e,cache.next++);
    const id=cache.ids.get(e); cache.nodes.set(id,e); return id;
  };
  for (const [id,e] of cache.nodes) if (!e.isConnected) cache.nodes.delete(id);
  const safe = e => !['password','file','hidden'].includes(e.type);
  // Inputs whose value is set rather than typed: the browser draws its own
  // segmented control and no keystroke reaches it.
  const PICKERS = ['date','datetime-local','month','week','time'];
  // A dropdown's options are the choices in it, never a name for it: run
  // together they read as a label made of everything it could be.
  const SPOKEN_FOR = ['OPTION','OPTGROUP'];
  const visible = e => !e.closest('[aria-hidden="true"],[inert]') &&
    e.checkVisibility({checkOpacity:true,checkVisibilityCSS:true});
  const name = (e,seen=new Set()) => {
    if (!e || seen.has(e)) return '';
    seen.add(e);
    const referenced=(e.getAttribute('aria-labelledby')||'').split(/\s+/)
      .map(id=>name(document.getElementById(id),seen)).filter(Boolean).join(' ');
    return referenced || e.getAttribute('aria-label') ||
      [...(e.labels||[])].map(l=>name(l,seen)).filter(Boolean).join(' ') ||
      (['button','submit','reset'].includes(e.type) ? e.value : '') || e.getAttribute('alt') ||
      (e.tagName==='INPUT' ? '' : [...e.childNodes].map(n=>n.nodeType===3 ? n.textContent :
        n.nodeType===1 && n.getAttribute('aria-hidden')!=='true' && !SPOKEN_FOR.includes(n.tagName)
          ? name(n,seen) : '').join(' ').trim()) ||
      // A dropdown nobody labelled is known by what it says while nothing is
      // chosen, which is the first option and what a person reads on the page.
      (e.tagName==='SELECT' ? (e.options[0]?.label||'').trim() : '') ||
      e.getAttribute('title') || e.getAttribute('placeholder') || '';
  };
  // A grid cell's own text is a number in a column of numbers, and the editor
  // inside one has no name at all. What tells them apart is the column they sit
  // under and the row they are in, which the grid already publishes as
  // `aria-colindex` on the cell and a `columnheader` carrying the same index.
  const placed = e => {
    const cell = e.matches('[role="gridcell"]') ? e : e.closest('[role="gridcell"]');
    if (!cell) return '';
    const index = cell.getAttribute('aria-colindex'), grid = cell.closest('[role="grid"],[role="treegrid"]');
    const header = index && grid &&
      grid.querySelector('[role="columnheader"][aria-colindex="'+CSS.escape(index)+'"]');
    const row = cell.closest('[role="row"]')?.getAttribute('aria-rowindex');
    return [header ? name(header) : '', row ? 'row '+row : ''].filter(Boolean).join(' ');
  };
  const roles=['button','link','checkbox','radio','switch','tab','menuitem','menuitemradio',
    'option','gridcell','combobox','textbox','searchbox','spinbutton'];
  const selector='a[href],button,input,textarea,select,summary,[contenteditable="true"],'+
    roles.map(role=>'[role="'+role+'"]').join(',');
  const role = e => {
    const explicit=e.getAttribute('role');
    if (roles.includes(explicit)) return explicit;
    if (e.tagName==='BUTTON' || e.tagName==='SUMMARY') return 'button';
    if (e.tagName==='A') return 'link';
    if (e.tagName==='SELECT') return 'combobox';
    if (e.tagName==='TEXTAREA' || e.isContentEditable) return 'textbox';
    if (e.tagName==='INPUT') {
      if (['checkbox','radio'].includes(e.type)) return e.type;
      if (['button','submit','reset','image'].includes(e.type)) return 'button';
      if (e.type==='search') return 'searchbox';
      if (e.type==='number') return 'spinbutton';
      if (['text','email','url','tel'].includes(e.type)) return 'textbox';
      // A date or time input holds text the same way, even though the browser
      // draws it as segments nothing can be typed into.
      if (PICKERS.includes(e.type)) return 'textbox';
    }
    return null;
  };
  cache.pageKey=()=>[performance.timeOrigin,location.href,scrollX,scrollY,innerWidth,innerHeight,
    [...document.querySelectorAll('input,textarea,select')].filter(safe)
      .map(e=>[identity(e),e.value,e.checked,e.selectedIndex,e.disabled,e.readOnly])];
  cache.guard=e=>{
    if (!e?.isConnected || !visible(e)) return null;
    const scope=e.closest('form,dialog,[role="dialog"],article,li,tr,[role="row"]') || e.parentElement;
    return [identity(e),role(e),name(e),e.value??null,e.checked??null,e.selectedIndex??null,
      e.readOnly??null,e.matches(':disabled'),e.getAttribute('aria-disabled'),
      e.getAttribute('aria-expanded'),e.getAttribute('aria-checked'),e.getAttribute('aria-selected'),
      e.getAttribute('href'),scope?.innerText?.slice(0,6000)||''];
  };
  // A dropdown with two thousand vendors in it would be two thousand entries, and
  // the page's own buttons would fall off the end of the list behind them. What
  // is kept is enough to choose from; what is dropped is counted and said.
  const OPTIONS_PER_DROPDOWN=40;
  const actions=[]; let omitted_options=0;
  for (const e of document.querySelectorAll(selector)) {
    if (!safe(e) || !visible(e) || e.matches(':disabled') || e.closest('[aria-disabled="true"]')) continue;
    const r=e.getBoundingClientRect(), x=r.x+r.width/2, y=r.y+r.height/2, rname=role(e);
    if (!rname || r.width<=0 || r.height<=0 || x<0 || y<0 || x>=innerWidth || y>=innerHeight) continue;
    if (rname==='gridcell' && e.querySelector('button,[role="button"]')) continue;
    const base={node:identity(e),role:rname,label:[placed(e),name(e)].filter(Boolean).join(' · ')||rname,
      rect:{x:r.x,y:r.y,w:r.width,h:r.height}};
    for (const key of ['checked','selected','expanded']) {
      const value=e.getAttribute('aria-'+key);
      if (value!==null) base[key]=value;
    }
    if (['checkbox','radio'].includes(e.type)) base.checked=String(e.checked);
    if (e.tagName==='SELECT') {
      // An option with no value is the prompt to choose one - "Select a
      // location" - so offering it is offering to choose nothing, which reads as
      // carrying the instruction out and is how the same choice gets made twice.
      let listed=0;
      for (const o of e.options) {
        if (o.value==='' || o.selected || o.disabled || o.closest('optgroup[disabled]')) continue;
        if (listed++ >= OPTIONS_PER_DROPDOWN) { omitted_options++; continue; }
        actions.push({...base,kind:'select',value:o.value,
          current_value:[...e.selectedOptions].map(o=>o.label).join(', '),label:base.label+' → '+o.label});
      }
    } else {
      const editable=!e.readOnly && e.getAttribute('aria-readonly')!=='true' &&
        (['textbox','searchbox','spinbutton'].includes(rname) ||
          (rname==='combobox' && ['INPUT','TEXTAREA'].includes(e.tagName)));
      const value='value' in e ? String(e.value) :
        e.isContentEditable || rname==='combobox' ? e.innerText.trim() : '';
      if (PICKERS.includes(e.type)) base.picker=true;
      actions.push({...base,kind:editable?'fill':'click',value});
      if (editable) actions.push({...base,kind:'click',value,label:'Open '+base.label});
    }
  }
  const words=[], walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
  const range=document.createRange(); let node,length=0;
  while ((node=walker.nextNode()) && length<6000) {
    const value=node.textContent.trim(), parent=node.parentElement;
    if (!value || !parent || parent.closest('script,style,noscript,template') || !visible(parent)) continue;
    range.selectNodeContents(node); const r=range.getBoundingClientRect();
    if (r.width>0 && r.height>0 && r.bottom>0 && r.top<innerHeight && r.right>0 && r.left<innerWidth) {
      words.push(value); length+=value.length;
    }
  }
  const text=words.join('\n').slice(0,6000), height=document.documentElement.scrollHeight;
  const page_key=cache.pageKey(), guards={};
  for (const a of actions) if (!(a.node in guards)) guards[a.node]=cache.guard(cache.nodes.get(a.node));
  // Compare meaning and identity. Geometry is always resolved and hit-tested just before input.
  const semantics=actions.map(({rect,...action})=>action);
  const marker=[performance.timeOrigin,location.href,scrollX,scrollY,innerWidth,innerHeight,
    document.title,text,semantics,page_key[6]];
  const omitted_actions=Math.max(0,actions.length-250);
  actions.splice(250);
  actions.forEach((a,i)=>a.id='e'+(i+1));
  // Where the page came from is somewhere it can be sent, and a form abandoned by
  // following a link is only recoverable this way.
  if (history.length>1) actions.push({id:'back',kind:'back',label:'Go back to the previous page'});
  if (scrollY+innerHeight<height-2) actions.push({id:'scroll_down',kind:'scroll',label:'Scroll down',delta:560});
  if (scrollY>0) actions.push({id:'scroll_up',kind:'scroll',label:'Scroll up',delta:-560});
  actions.push({id:'wait',kind:'wait',label:'Wait for the page to update'});
  return {url:location.href,title:document.title,w:innerWidth,h:innerHeight,text,
    scroll:{y:scrollY,height},actions,marker,page_key,guards,omitted_actions,omitted_options};
})()
