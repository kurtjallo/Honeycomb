// jsdom has no layout, and ProseMirror measures text ranges when it scrolls the cursor into view.
Range.prototype.getClientRects = () => [] as unknown as DOMRectList
Range.prototype.getBoundingClientRect = () => new DOMRect()
