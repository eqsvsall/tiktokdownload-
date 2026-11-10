/** Halaman utama (/) diarahkan ke public/index.html */
module.exports = {
  async rewrites() {
    return { beforeFiles: [{ source: '/', destination: '/index.html' }] };
  },
};
