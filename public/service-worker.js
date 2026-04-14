self.addEventListener('install', () => {
  console.log('SealRoute App installed')
})

self.addEventListener('activate', () => {
  console.log('SealRoute App activated')
})

self.addEventListener('fetch', (event) => {
  event.respondWith(fetch(event.request))
})
