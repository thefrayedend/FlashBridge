const { chromium } = require('playwright'); const S = process.argv[2]; const kill = process.argv[3] === 'kill';
const { execSync } = require('child_process');
(async () => { const b = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined, args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] }); const p = await b.newPage();
  p.on('pageerror', e => console.log('PAGEERR', e.message));
  await p.goto('http://localhost:8088/#slicer/prepare'); await p.waitForTimeout(4000);
  await p.setInputFiles('#sl-file', [`${S}/models/vase.3mf`]); await p.waitForTimeout(5000);
  await p.click('#mode-tabs a[data-mode="preview"]');
  let seen = false;
  for (let i = 0; i < 120; i++) {
    await p.waitForTimeout(1000);
    let pid = ''; try { pid = execSync('pgrep -x slicer_cli-orca').toString().trim().split('\n')[0]; } catch {}
    if (pid && !seen) { seen = true;
      console.log('engine', execSync(`taskset -cp ${pid}`).toString().trim(), '| oom_score_adj', execSync(`cat /proc/${pid}/oom_score_adj`).toString().trim(), '| nice', execSync(`ps -o ni= -p ${pid}`).toString().trim());
      const ai = await p.evaluate(() => fetch('/api/status').then(r => r.json()).then(j => j.aiService || j.ai));
      console.log('ai service while slicing:', JSON.stringify(ai && { pausedForSlicer: ai.pausedForSlicer }));
      if (kill) { await p.waitForTimeout(3000); execSync(`kill -9 ${pid}`); console.log('killed engine with SIGKILL (as the out-of-memory killer would)'); }
    }
    const st = await p.evaluate(() => fetch('/api/slicer').then(r => r.json()).then(j => j.jobs && j.jobs['1']).catch(() => null)); if (st && seen && ['done','failed','cancelled','error'].includes(st.state)) { console.log('job', st.state, '|', st.error || st.message || '', '|', st.stats ? JSON.stringify(st.stats).slice(0, 120) : ''); break; }
  }
  await p.waitForTimeout(23000);
  const ai2 = await p.evaluate(() => fetch('/api/status').then(r => r.json()).then(j => j.aiService || j.ai));
  console.log('ai service 23 s later:', JSON.stringify(ai2 && { pausedForSlicer: ai2.pausedForSlicer }));
  await b.close(); })();
