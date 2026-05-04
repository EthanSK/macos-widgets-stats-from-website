//
//  InspectOverlayJS.swift
//  MacosWidgetsStatsFromWebsite
//
//  JavaScript injected into the visible browser for element picking.
//

enum InspectOverlayJS {
    static let inspectOverlayJS = #"""
(() => {
  try {
    if (window.__statsWidgetInspectCleanup) {
      window.__statsWidgetInspectCleanup();
    }

    const root = document.body || document.documentElement;
    if (!root) {
      throw new Error('No document root is available.');
    }

    const outline = document.createElement('div');
    outline.setAttribute('data-stats-widget-inspect-outline', 'true');
    outline.style.cssText = 'position:fixed;border:2px solid #2997ff;box-sizing:border-box;pointer-events:none;z-index:2147483647;display:none;';
    root.appendChild(outline);

    let hoverElement = null;
    window.__statsWidgetHover = null;

    function postError(error) {
      const message = String(error && error.message ? error.message : error);
      if (window.webkit && webkit.messageHandlers && webkit.messageHandlers.inspectError) {
        webkit.messageHandlers.inspectError.postMessage({ message });
      } else {
        window.__statsWidgetInspectError = { message };
        console.error(message);
      }
    }

    function postCanceled() {
      if (window.webkit && webkit.messageHandlers && webkit.messageHandlers.inspectCanceled) {
        webkit.messageHandlers.inspectCanceled.postMessage({});
      }
      window.__statsWidgetInspectCanceled = true;
    }

    function isElement(value) {
      return value && value.nodeType === Node.ELEMENT_NODE;
    }

    function tagName(element) {
      return element.tagName.toLowerCase();
    }

    function escapeAttributeValue(value) {
      return String(value)
        .replace(/\\/g, '\\\\')
        .replace(/"/g, '\\"')
        .replace(/\n/g, '\\A ')
        .replace(/\r/g, '\\A ');
    }

    function queryCount(selector) {
      try {
        return document.querySelectorAll(selector).length;
      } catch (_) {
        return 0;
      }
    }

    function attributeSelector(element, attributes) {
      for (const attribute of attributes) {
        const value = element.getAttribute(attribute);
        if (!value) {
          continue;
        }

        const selector = '[' + attribute + '="' + escapeAttributeValue(value) + '"]';
        if (queryCount(selector) === 1) {
          return selector;
        }

        const taggedSelector = tagName(element) + selector;
        if (queryCount(taggedSelector) === 1) {
          return taggedSelector;
        }
      }

      return null;
    }

    function nthChildSegment(element) {
      let index = 1;
      let sibling = element;
      while ((sibling = sibling.previousElementSibling)) {
        index += 1;
      }
      return tagName(element) + ':nth-child(' + index + ')';
    }

    function synthesiseSelector(element) {
      const direct = attributeSelector(element, ['data-testid', 'id', 'aria-label', 'name']);
      if (direct) {
        return direct;
      }

      const segments = [];
      let node = element;
      while (isElement(node)) {
        const anchor = node === element ? null : attributeSelector(node, ['data-testid', 'id']);
        if (anchor) {
          segments.unshift(anchor);
          const anchoredSelector = segments.join(' > ');
          if (queryCount(anchoredSelector) === 1) {
            return anchoredSelector;
          }
        }

        segments.unshift(nthChildSegment(node));
        const selector = segments.join(' > ');
        if (queryCount(selector) === 1) {
          return selector;
        }

        node = node.parentElement;
      }

      const fallback = segments.join(' > ');
      if (fallback) {
        return fallback;
      }

      throw new Error('Could not build a selector for the selected element.');
    }

    function elementText(element) {
      return String(element.innerText || element.textContent || '').trim();
    }

    function updateOutline(element) {
      const rect = element.getBoundingClientRect();
      Object.assign(outline.style, {
        display: 'block',
        left: rect.left + 'px',
        top: rect.top + 'px',
        width: rect.width + 'px',
        height: rect.height + 'px'
      });
    }

    function cleanup() {
      document.removeEventListener('mousemove', onMove, true);
      document.removeEventListener('click', onClick, true);
      document.removeEventListener('keydown', onKeyDown, true);
      if (outline.parentNode) {
        outline.parentNode.removeChild(outline);
      }
      window.__statsWidgetHover = null;
      window.__statsWidgetInspectCleanup = null;
    }

    function onMove(event) {
      if (!isElement(event.target)) {
        return;
      }

      hoverElement = event.target;
      window.__statsWidgetHover = hoverElement;
      updateOutline(hoverElement);
    }

    function onClick(event) {
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();

      try {
        const element = hoverElement || event.target;
        if (!isElement(element)) {
          throw new Error('No element is currently under the pointer.');
        }

        const rect = element.getBoundingClientRect();
        const selector = synthesiseSelector(element);
        const payload = {
          selector,
          text: elementText(element),
          bbox: {
            x: rect.left,
            y: rect.top,
            width: rect.width,
            height: rect.height,
            viewportWidth: window.innerWidth,
            viewportHeight: window.innerHeight,
            devicePixelRatio: window.devicePixelRatio || 1
          }
        };

        if (window.webkit && webkit.messageHandlers && webkit.messageHandlers.elementPicked) {
          webkit.messageHandlers.elementPicked.postMessage(payload);
        } else {
          window.__statsWidgetPicked = payload;
        }
        cleanup();
      } catch (error) {
        postError(error);
        cleanup();
      }
    }

    function onKeyDown(event) {
      if (event.key === 'Escape') {
        event.preventDefault();
        event.stopPropagation();
        cleanup();
        postCanceled();
      }
    }

    window.__statsWidgetInspectCleanup = cleanup;
    document.addEventListener('mousemove', onMove, true);
    document.addEventListener('click', onClick, true);
    document.addEventListener('keydown', onKeyDown, true);
  } catch (error) {
    const message = String(error && error.message ? error.message : error);
    if (window.webkit && webkit.messageHandlers && webkit.messageHandlers.inspectError) {
      webkit.messageHandlers.inspectError.postMessage({ message });
    } else {
      window.__statsWidgetInspectError = { message };
      console.error(message);
    }
  }
})();
"""#
}
