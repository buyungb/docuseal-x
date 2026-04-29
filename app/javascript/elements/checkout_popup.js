// Wraps the "Buy license" form. Intercepts the submit, calls the server to
// create a checkout session, then opens the returned payment_url inside a
// SweetAlert2 modal (iframe), so the payment is never blocked by popup
// blockers and stays inside the app shell.
//
// Also keeps a live "Total = unit_price * seats" display in sync with the
// seats input.

const SWAL_SRC = '/vendor/sweetalert2/sweetalert2.all.min.js'

let swalLoadPromise = null

const loadSweetAlert = () => {
  if (window.Swal) return Promise.resolve(window.Swal)
  if (swalLoadPromise) return swalLoadPromise

  swalLoadPromise = new Promise((resolve, reject) => {
    const existing = document.querySelector('script[data-sweetalert2]')
    const script = existing || document.createElement('script')

    if (!existing) {
      script.src = SWAL_SRC
      script.async = true
      script.dataset.sweetalert2 = 'true'
      document.head.appendChild(script)
    }

    script.addEventListener('load', () => resolve(window.Swal), { once: true })
    script.addEventListener('error', () => reject(new Error('Failed to load SweetAlert2')), { once: true })
  })

  return swalLoadPromise
}

const formatIdr = (value) => {
  try {
    return new Intl.NumberFormat('id-ID').format(value)
  } catch (_) {
    return String(value)
  }
}

export default class extends HTMLElement {
  connectedCallback () {
    this.form = this.querySelector('form')
    if (!this.form) return

    this.statusEl = this.querySelector('[data-target="checkout-popup.status"]')
    this.totalEl = this.querySelector('[data-target="checkout-popup.total"]')
    this.seatsEl = this.querySelector('[data-target="checkout-popup.seats"]')
    this.button = this.form.querySelector('button[type="submit"], input[type="submit"]')

    this.unitPrice = parseInt(this.dataset.unitPrice || '0', 10) || 0

    this.onSubmit = this.handleSubmit.bind(this)
    this.onSeatsInput = this.updateTotal.bind(this)

    this.form.addEventListener('submit', this.onSubmit)
    this.seatsEl?.addEventListener('input', this.onSeatsInput)
    this.seatsEl?.addEventListener('change', this.onSeatsInput)

    this.updateTotal()
    loadSweetAlert().catch(() => {})
  }

  disconnectedCallback () {
    this.form?.removeEventListener('submit', this.onSubmit)
    this.seatsEl?.removeEventListener('input', this.onSeatsInput)
    this.seatsEl?.removeEventListener('change', this.onSeatsInput)
  }

  currentSeats () {
    const raw = parseInt(this.seatsEl?.value || '1', 10)
    return Number.isFinite(raw) && raw >= 1 ? raw : 1
  }

  updateTotal () {
    if (!this.totalEl || !this.unitPrice) return
    const total = this.unitPrice * this.currentSeats()
    this.totalEl.textContent = formatIdr(total)
  }

  async handleSubmit (event) {
    event.preventDefault()

    this.setBusy(true)
    this.setStatus('Creating checkout session...', 'info')

    try {
      const formData = new FormData(this.form)
      const response = await fetch(this.form.action, {
        method: this.form.method || 'POST',
        body: formData,
        headers: {
          Accept: 'application/json',
          'X-Requested-With': 'XMLHttpRequest'
        },
        credentials: 'same-origin'
      })

      const payload = await response.json().catch(() => ({}))

      if (!response.ok) {
        this.setStatus(payload.error || `Checkout failed (${response.status})`, 'error')
        return
      }

      if (!payload.payment_url) {
        this.setStatus('No payment URL was returned. Please try again.', 'error')
        return
      }

      this.setStatus('', 'info')
      await this.openPaymentModal(payload.payment_url)
    } catch (err) {
      this.setStatus(err?.message || 'Network error while creating the checkout session.', 'error')
    } finally {
      this.setBusy(false)
    }
  }

  async openPaymentModal (paymentUrl) {
    let Swal
    try {
      Swal = await loadSweetAlert()
    } catch (_) {
      window.open(paymentUrl, '_blank', 'noopener,noreferrer')
      this.setStatus(
        'Opened the checkout in a new tab. Complete payment, then paste the license key below to activate.',
        'success'
      )
      return
    }

    await Swal.fire({
      title: 'Complete your payment',
      html: `
        <div style="display:flex;flex-direction:column;gap:8px">
          <iframe
            src="${paymentUrl}"
            style="width:100%;height:70vh;border:0;border-radius:8px;background:#fff"
            allow="payment *"
            referrerpolicy="no-referrer-when-downgrade"></iframe>
          <div style="font-size:12px;color:#666;text-align:left">
            Trouble loading?
            <a href="${paymentUrl}" target="_blank" rel="noopener noreferrer">
              Open in a new tab
            </a>.
          </div>
        </div>
      `,
      width: 'min(960px, 95vw)',
      padding: '1rem',
      showConfirmButton: true,
      confirmButtonText: 'I have completed payment',
      showCancelButton: true,
      cancelButtonText: 'Cancel',
      showCloseButton: true,
      allowOutsideClick: false,
      allowEscapeKey: true,
      focusConfirm: false
    })

    this.setStatus(
      'After payment, paste the license key from the success page below and click Activate.',
      'success'
    )
  }

  setBusy (busy) {
    if (!this.button) return
    if (busy) {
      this.button.dataset.originalText = this.button.dataset.originalText || this.button.textContent
      this.button.disabled = true
    } else {
      this.button.disabled = false
    }
  }

  setStatus (message, level = 'info') {
    if (!this.statusEl) return
    const colorClass = {
      info: 'text-base-content/70',
      success: 'text-success',
      error: 'text-error'
    }[level] || 'text-base-content/70'
    this.statusEl.className = `text-sm mt-2 ${colorClass}`
    this.statusEl.textContent = message
  }
}
