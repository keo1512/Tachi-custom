// Original compatibility host. Native bridges exchange bounded JSON strings;
// extension scripts receive no Swift objects, file system, or app references.
(function (global) {
  function fail(code, message) { var error = new Error(message); error.code = code; throw error; }
  function bridge(name, value) {
    var result = JSON.parse(global[name](JSON.stringify(value)));
    if (result.error) fail(result.error.code || 'NATIVE_ERROR', result.error.message);
    return result.value;
  }
  function selection(handle) {
    var result = {
      _handle: handle,
      size: function () { return this.length; },
      isEmpty: function () { return this.length === 0; },
      get: function (index) { return operation(this, 'get', [Number(index)]); },
      first: function () { return this.get(0); },
      last: function () { return this.get(this.length - 1); },
      select: function (query) { return operation(this, 'select', [String(query)]); },
      children: function () { return operation(this, 'children', []); },
      child: function (index) { return this.children().get(index); },
      parent: function () { return operation(this, 'parent', []); },
      next: function () { return operation(this, 'next', []); },
      prev: function () { return operation(this, 'prev', []); },
      text: function (value) { return property(this, 'text', value); },
      html: function (value) { return property(this, 'html', value); },
      tagName: function (value) { return property(this, 'tagName', value); },
      ownText: function () { return bridge('__nativeHtml', {handle:this._handle, op:'ownText'}); },
      outerHtml: function () { return bridge('__nativeHtml', {handle:this._handle, op:'outerHtml'}); },
      attributes: function () { return bridge('__nativeHtml', {handle:this._handle, op:'attributes'}); },
      attr: function (key, value) {
        var args = [String(key)];
        if (value !== undefined) args.push(String(value));
        var output = bridge('__nativeHtml', {handle:this._handle, op:'attr', args:args});
        return value === undefined ? output : this;
      },
      remove: function () { bridge('__nativeHtml', {handle:this._handle, op:'remove'}); return this; },
      removeAttr: function (key) { bridge('__nativeHtml', {handle:this._handle, op:'removeAttr', args:[String(key)]}); return this; },
      toArray: function () { var a = []; for (var i=0; i<this.length; i++) a.push(this.get(i)); return a; },
      forEach: function (callback) { return this.toArray().forEach(callback); },
      map: function (callback) { return this.toArray().map(callback); },
      toString: function () { return this.html(); }
    };
    Object.defineProperty(result, 'length', {get:function () {return bridge('__nativeHtml', {handle:handle, op:'size'});}});
    result[Symbol.iterator] = function () { return this.toArray()[Symbol.iterator](); };
    return new Proxy(result, {get:function (target, key) {
      return typeof key === 'string' && /^\d+$/.test(key) ? target.get(Number(key)) : target[key];
    }});
  }
  function operation(item, op, args) { return selection(bridge('__nativeHtml', {handle:item._handle, op:op, args:args})); }
  function property(item, op, value) {
    var args = value === undefined ? [] : [String(value)];
    var result = bridge('__nativeHtml', {handle:item._handle, op:op, args:args});
    return value === undefined ? result : item;
  }
  function blob(base64, type) {
    return {_isBlob:true, _base64:String(base64 || ''), type:String(type || ''),
      base64:function () {return this._base64;}, toString:function () {return this._base64;}};
  }
  function storage(backing) {
    return {
      getItem:function (key) {return Object.prototype.hasOwnProperty.call(backing, String(key)) ? backing[String(key)] : null;},
      setItem:function (key,value) {
        key=String(key); value=String(value);
        if (key.length+value.length>1024*1024) fail('EXECUTION_LIMIT','Storage item exceeds limit.');
        backing[key]=value;
        if (JSON.stringify(backing).length>2*1024*1024) fail('EXECUTION_LIMIT','Storage exceeds limit.');
      },
      removeItem:function (key) {delete backing[String(key)];},
      clear:function () {Object.keys(backing).forEach(function (key) {delete backing[key];});}
    };
  }
  function unsupported(name) {
    var f=function () {fail('UNSUPPORTED_CAPABILITY',name+' is not supported by this engine.');};
    return new Proxy(f,{get:f,apply:f,construct:f});
  }
  global.__runVbook = function (payload) {
    var persistent=Object.assign(Object.create(null),payload.storage || {}), logs=[];
    var scripts=payload.scripts, manifest=payload.manifest, active=Object.create(null), loadedBytes=0;
    global.Html={parse:function (html) {return selection(bridge('__nativeHtml',{op:'parse',args:[String(html)]}));},
      clean:function (html,tags) {return bridge('__nativeHtml',{op:'clean',args:[String(html),Array.from(tags || [])]});}};
    global.fetch=function (url,options) {
      var result=bridge('__nativeFetch',{url:String(url),options:options || {}});
      result.text=function (charset) {return bridge('__nativeDecode',{base64:result.base64Data,charset:charset || result.charset || 'utf-8'});};
      result.json=function () {return JSON.parse(this.text());};
      result.html=function (charset) {return global.Html.parse(this.text(charset));};
      result.header=function (name) {return result.headers[String(name).toLowerCase()] || '';};
      result.base64=function () {return result.base64Data;};
      result.blob=function () {return blob(result.base64Data,result.headers['content-type']);};
      return result;
    };
    function builder(url,method) {
      var options={method:method};
      return {headers:function (v) {options.headers=v;return this;},
        queries:function (v) {options.queries=v;return this;}, params:function (v) {options.queries=v;return this;},
        body:function (v) {options.body=v;return this;}, binary:function (v,t) {options.body=blob(v,t);return this;},
        timeout:function (v) {options.timeout=v;return this;}, url:function () {return url;},
        string:function (c) {return global.fetch(url,options).text(c);}, html:function (c) {return global.fetch(url,options).html(c);},
        blob:function () {return global.fetch(url,options).blob();}};
    }
    global.Http={get:function (url) {return builder(url,'GET');},post:function (url) {return builder(url,'POST');}};
    global.Response={success:function (data,data2) {return JSON.stringify({code:0,data:data,data2:data2});},
      error:function (data) {return JSON.stringify({code:1,data:data});}};
    global.localStorage=storage(persistent); global.cacheStorage=storage(Object.create(null));
    global.Blob={fromBase64:blob};
    var log=function (message) {if(logs.length<200)logs.push(String(message).slice(0,1000));};
    global.Console={log:log};global.Log={log:log};global.console={log:log};
    global.UserAgent={system:function () {return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1';},
      ios:function () {return this.system();}, android:function () {return 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/125.0.0.0 Mobile Safari/537.36';},
      chrome:function () {return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/125.0.0.0 Safari/537.36';}};
    ['Engine','localCookie','localConfig','localDatabase','localBook','Graphics','WebSocket','Qt','QT','Script'].forEach(function(name){global[name]=unsupported(name);});
    global.sleep=function (milliseconds) {bridge('__nativeSleep',{milliseconds:Number(milliseconds) || 0});};
    global.load=function (name) {
      name=String(name);
      if(name==='crypto.js') {
        if(!global.CryptoJS || !global.CryptoJS.AES)fail('ENGINE_RESOURCE_MISSING','CryptoJS resource is missing.');
        return global.CryptoJS;
      }
      if(!/^[^/\\:\x00]+\.js$/.test(name)||!Object.prototype.hasOwnProperty.call(scripts,name))fail('SCRIPT_MISSING','Missing local script: '+name);
      if(active[name])fail('CIRCULAR_LOAD','Circular load: '+name);
      loadedBytes+=scripts[name].length;
      if(loadedBytes>32*1024*1024)fail('EXECUTION_LIMIT','Loaded script limit exceeded.');
      active[name]=true;
      try{return (0,eval)(scripts[name]);}finally{delete active[name];}
    };
    var constants=[];
    Object.keys(manifest.config || {}).forEach(function(name){
      var definition=manifest.config[name];
      if(definition && definition.mode==='database')return;
      if(!/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name))fail('INVALID_CONFIG','Invalid static config name.');
      var value=Object.prototype.hasOwnProperty.call(payload.config || {},name) ? payload.config[name] :
        definition && typeof definition==='object' ? definition.default || '' : definition;
      constants.push('const '+name+' = '+JSON.stringify(String(value == null ? '' : value))+';');
    });
    if(!Object.prototype.hasOwnProperty.call(scripts,payload.script))fail('SCRIPT_MISSING','Entry script is missing.');
    global.__vbookArgs=(payload.args || []).map(function(value){return String(value == null ? '' : value);});
    var raw=(0,eval)(constants.join('\n')+'\n'+scripts[payload.script]+'\n;execute.apply(null,__vbookArgs);');
    if(typeof raw!=='string')fail('INVALID_SCRIPT_RESPONSE','execute() must return Response JSON.');
    if(raw.length>16*1024*1024)fail('EXECUTION_LIMIT','Result exceeds limit.');
    var response=JSON.parse(raw);
    if(response.code!==0)fail('SOURCE_ERROR',String(response.data || 'Extension returned an error.'));
    return JSON.stringify({data:response.data,data2:response.data2,storage:persistent,logs:logs});
  };
})(this);
