const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined }); const pg = await b.newPage({ viewport: { width: 1280, height: 760 } });
  await pg.goto('http://localhost:8088/#home'); await pg.waitForTimeout(3000);
  const st = await (await fetch('http://localhost:8088/api/status')).json(); const id = st.printers[0].id;
  fetch(`http://localhost:8088/api/printers/${id}/print`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ file: process.argv[3], mappings: [{ toolId: 0, slotId: 1 }] }) }).then(r => r.json()).then(j => console.log('print answer:', JSON.stringify(j)));
  for (const t of [3, 9, 17, 24, 34]) {
    await pg.waitForTimeout(t === 3 ? 3000 : (t - [3, 9, 17, 24, 34][[3, 9, 17, 24, 34].indexOf(t) - 1]) * 1000);
    console.log(`t=${t}s tab: ${(await pg.textContent('#printer-tabs')).trim()} | ${await pg.textContent('#job-title')} | ${await pg.textContent('#job-sub')} | ${await pg.textContent('#job-stats')}`);
    if (t === 17) await pg.screenshot({ path: (process.env.FB_OUT || '/tmp') + '/stage-unpack.png' });
  }
  await b.close();
})();
