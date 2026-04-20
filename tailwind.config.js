module.exports = {
  plugins: [
    require('daisyui')
  ],
  theme: {
    extend: {
      boxShadow: {
        'soft': '0 1px 3px 0 rgba(20, 28, 43, 0.06), 0 1px 2px -1px rgba(20, 28, 43, 0.06)',
        'medium': '0 4px 6px -1px rgba(20, 28, 43, 0.08), 0 2px 4px -2px rgba(20, 28, 43, 0.06)',
        'large': '0 10px 15px -3px rgba(20, 28, 43, 0.08), 0 4px 6px -4px rgba(20, 28, 43, 0.06)',
        'xl': '0 20px 25px -5px rgba(20, 28, 43, 0.08), 0 8px 10px -6px rgba(20, 28, 43, 0.06)',
        'glow': '0 0 20px hsla(185, 75%, 45%, 0.35)',
        'primary-glow': '0 0 30px hsla(220, 65%, 28%, 0.3)',
      },
      backgroundImage: {
        'gradient-hero': 'linear-gradient(135deg, #193468 0%, #1a6a8f 50%, #1db8b8 100%)',
        'gradient-primary': 'linear-gradient(135deg, #193468 0%, #2a4a7a 100%)',
        'gradient-accent': 'linear-gradient(135deg, #1db8b8 0%, #26c9a8 100%)',
        'gradient-subtle': 'linear-gradient(180deg, #f4f7f9 0%, #e8ecf0 100%)',
      },
    },
  },
  daisyui: {
    themes: [
      {
        sealroute: {
          'color-scheme': 'light',
          primary: '#193468',
          'primary-content': '#ffffff',
          secondary: '#212f45',
          'secondary-content': '#eef2f5',
          accent: '#1db8b8',
          'accent-content': '#ffffff',
          neutral: '#141d2b',
          'neutral-content': '#eef2f5',
          info: '#1a9ff5',
          success: '#249964',
          warning: '#f5a623',
          error: '#e02424',
          'base-100': '#ffffff',
          'base-200': '#f4f7f9',
          'base-300': '#d1d9e2',
          'base-content': '#141c2b',
          '--rounded-btn': '0.5rem',
          '--rounded-box': '1rem',
          '--tab-border': '2px',
          '--tab-radius': '.5rem'
        }
      }
    ]
  }
}
