import { load } from 'cheerio';

export class HtmlSelection {
  constructor(root, selection) {
    this.root = root;
    this.selection = selection;
    return new Proxy(this, { get(target, property, receiver) {
      if (typeof property === 'string' && /^\d+$/.test(property)) return target.get(Number(property));
      return Reflect.get(target, property, receiver);
    } });
  }
  get length() { return this.selection.length; }
  size() { return this.length; }
  isEmpty() { return this.length === 0; }
  select(selector) {
    selector = String(selector);
    return new HtmlSelection(this.root, this.selection.filter(selector).add(this.selection.find(selector)));
  }
  get(index) {
    index = Number(index);
    return new HtmlSelection(this.root, Number.isInteger(index) && index >= 0
      ? this.selection.eq(index) : this.root([]));
  }
  first() { return this.get(0); }
  last() { return new HtmlSelection(this.root, this.selection.last()); }
  text(value) {
    if (value !== undefined) { this.selection.text(String(value)); return this; }
    return this.selection.toArray().map(node => this.root(node).text()).join(' ').replace(/\s+/g, ' ').trim();
  }
  ownText() { return this.selection.first().contents().toArray().filter(node => node.type === 'text')
    .map(node => node.data).join('').trim(); }
  html(value) {
    if (value !== undefined) { this.selection.html(String(value)); return this; }
    return this.selection.toArray().map(node => this.root(node).html() ?? '').join('\n');
  }
  outerHtml() { return this.selection.toArray().map(node => this.root.html(node)).join('\n'); }
  attr(key, value) {
    if (value !== undefined) { this.selection.attr(String(key), String(value)); return this; }
    return this.selection.attr(String(key)) ?? '';
  }
  attributes() { return { ...(this.selection.get(0)?.attribs ?? {}) }; }
  remove() { this.selection.remove(); return this; }
  removeAttr(key) { this.selection.removeAttr(String(key)); return this; }
  children() { return new HtmlSelection(this.root, this.selection.children()); }
  child(index) { return this.children().get(index); }
  parent() { return new HtmlSelection(this.root, this.selection.parent()); }
  next() { return new HtmlSelection(this.root, this.selection.next()); }
  prev() { return new HtmlSelection(this.root, this.selection.prev()); }
  tagName(value) {
    if (value === undefined) return this.selection.get(0)?.name ?? '';
    if (!/^[a-z][a-z0-9:-]*$/i.test(String(value))) throw new TypeError('Invalid HTML tag name.');
    this.selection.each((_, node) => { node.name = String(value); });
    return this;
  }
  forEach(callback) { this.toArray().forEach(callback); }
  map(callback) { return this.toArray().map(callback); }
  toArray() { return this.selection.toArray().map(node => new HtmlSelection(this.root, this.root(node))); }
  toString() { return this.html(); }
  [Symbol.iterator]() { return this.toArray()[Symbol.iterator](); }
}

export function parseHtml(html) {
  const root = load(String(html));
  return new HtmlSelection(root, root.root());
}

export function cleanHtml(html, allowedTags = []) {
  const root = load(String(html));
  const allowed = new Set(Array.from(allowedTags, tag => String(tag).toLowerCase()));
  root('script,style,iframe,object,embed').remove();
  root('*').each((_, node) => {
    if (!allowed.has(node.name) && !['html', 'head', 'body'].includes(node.name)) root(node).replaceWith(root(node).contents());
  });
  return root('body').html() ?? '';
}

export function sanitizeChapter(html, baseUrl) {
  const root = load(String(html));
  root('script,style,iframe,object,embed,form,input,button,link,meta').remove();
  root('*').each((_, node) => {
    for (const key of Object.keys(node.attribs ?? {})) {
      if (key.toLowerCase().startsWith('on') || ['srcdoc', 'style'].includes(key.toLowerCase())) root(node).removeAttr(key);
    }
    for (const key of ['href', 'src']) {
      const value = root(node).attr(key);
      if (!value) continue;
      try {
        const url = new URL(value, baseUrl);
        if (!['http:', 'https:'].includes(url.protocol)) root(node).removeAttr(key);
        else root(node).attr(key, url.href);
      } catch { root(node).removeAttr(key); }
    }
  });
  return root('body').html() ?? '';
}
