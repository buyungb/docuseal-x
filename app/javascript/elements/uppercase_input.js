export default class extends HTMLElement {
  connectedCallback () {
    if (!this.input) return

    this.onInput = this.handleInput.bind(this)
    this.input.addEventListener('input', this.onInput)
  }

  disconnectedCallback () {
    this.input?.removeEventListener('input', this.onInput)
  }

  handleInput () {
    const start = this.input.selectionStart
    const end = this.input.selectionEnd
    const upper = this.input.value.toUpperCase()

    if (this.input.value !== upper) {
      this.input.value = upper

      try {
        this.input.setSelectionRange(start, end)
      } catch (_e) { /* ignore */ }
    }
  }

  get input () {
    return this.querySelector('input')
  }
}
