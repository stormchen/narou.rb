/**
 * Narou Modern Web UI - Core Application Logic
 * Pure ES6+, Zero External Dependencies
 */

(function () {
  'use strict';

  // State Management
  const state = {
    novels: [],
    selectedIds: new Set(),
    activeFilter: 'all',
    activeTag: null,
    searchKeyword: '',
    currentView: localStorage.getItem('narou_view_mode') || 'grid',
    theme: localStorage.getItem('narou_theme') || 'light',
    queueCount: 0,
    ws: null,
    wsConnected: false,
    systemStatus: null,
    wizardStep: 1,
    pendingConvertIds: [], // 記錄即將轉檔的小說 ID 清單
  };

  // DOM References
  const dom = {
    appVersionText: document.getElementById('appVersionText'),
    wsStatusDot: document.getElementById('wsStatusDot'),
    wsStatusText: document.getElementById('wsStatusText'),
    searchInput: document.getElementById('searchInput'),
    tagsCloud: document.getElementById('tagsCloud'),
    novelGridContainer: document.getElementById('novelGridContainer'),
    novelTableContainer: document.getElementById('novelTableContainer'),
    novelTableBody: document.getElementById('novelTableBody'),
    emptyState: document.getElementById('emptyState'),
    selectAllCheckbox: document.getElementById('selectAllCheckbox'),
    batchFloatingBar: document.getElementById('batchFloatingBar'),
    batchCountText: document.getElementById('batchCountText'),
    btnToggleConsole: document.getElementById('btnToggleConsole'),
    consoleDrawer: document.getElementById('consoleDrawer'),
    consoleLogs: document.getElementById('consoleLogs'),
    queueCountBadge: document.getElementById('queueCountBadge'),
    toastContainer: document.getElementById('toastContainer'),
    viewBtnGrid: document.getElementById('viewBtnGrid'),
    viewBtnList: document.getElementById('viewBtnList'),
    btnToggleTheme: document.getElementById('btnToggleTheme'),
    btnOpenDownloadModal: document.getElementById('btnOpenDownloadModal'),
    btnUpdateAll: document.getElementById('btnUpdateAll'),
    btnOpenSettingsModal: document.getElementById('btnOpenSettingsModal'),
    downloadModal: document.getElementById('downloadModal'),
    detailModal: document.getElementById('detailModal'),
    settingsModal: document.getElementById('settingsModal'),
    wizardModal: document.getElementById('wizardModal'),
    convertModal: document.getElementById('convertModal'),
  };

  // =========================================================================
  // Theme & Initialization
  // =========================================================================
  function initTheme() {
    document.documentElement.setAttribute('data-theme', state.theme);
    updateThemeIcon();
  }

  function toggleTheme() {
    state.theme = state.theme === 'dark' ? 'light' : 'dark';
    localStorage.setItem('narou_theme', state.theme);
    document.documentElement.setAttribute('data-theme', state.theme);
    updateThemeIcon();
  }

  function updateThemeIcon() {
    const isDark = state.theme === 'dark';
    if (dom.btnToggleTheme) {
      dom.btnToggleTheme.innerHTML = isDark
        ? `<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/></svg>`
        : `<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/></svg>`;
    }
  }

  // =========================================================================
  // Toast Notification System
  // =========================================================================
  function showToast(message, type = 'info') {
    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    toast.textContent = message;
    dom.toastContainer.appendChild(toast);

    requestAnimationFrame(() => {
      toast.classList.add('show');
    });

    setTimeout(() => {
      toast.classList.remove('show');
      setTimeout(() => toast.remove(), 250);
    }, 3200);
  }

  // =========================================================================
  // WebSocket & Push Server
  // =========================================================================
  function initWebSocket() {
    const host = window.location.hostname || '127.0.0.1';
    const port = parseInt(window.location.port, 10) + 1;
    const wsUrl = `ws://${host}:${port}/`;

    try {
      state.ws = new WebSocket(wsUrl);

      state.ws.onopen = () => {
        state.wsConnected = true;
        if (dom.wsStatusDot) dom.wsStatusDot.classList.remove('disconnected');
        if (dom.wsStatusText) dom.wsStatusText.textContent = '即時連線中';
      };

      state.ws.onclose = () => {
        state.wsConnected = false;
        if (dom.wsStatusDot) dom.wsStatusDot.classList.add('disconnected');
        if (dom.wsStatusText) dom.wsStatusText.textContent = '已離線 (重試中)';
        setTimeout(initWebSocket, 3000);
      };

      state.ws.onerror = () => {
        state.wsConnected = false;
        if (dom.wsStatusDot) dom.wsStatusDot.classList.add('disconnected');
      };

      state.ws.onmessage = (event) => {
        handleWsMessage(event.data);
      };
    } catch (e) {
      console.warn('WebSocket init failed:', e);
    }
  }

  function handleWsMessage(raw) {
    try {
      const data = JSON.parse(raw);
      if (data.stdout || data.stdout2) {
        appendConsoleLog(data.stdout || data.stdout2);
      }
      if (data['table.reload']) {
        loadNovelsList();
      }
      if (data['convert.finished']) {
        showToast('✓ 小說已成功轉換為電子書！', 'success');
        resetConvertingButtons();
        loadNovelsList();
      }
      if (data['server.rebooted']) {
        showToast('伺服器已重新啟動完成', 'success');
        loadNovelsList();
      }
      if (data['queue.update']) {
        updateQueueBadge(data['queue.update']);
      }
    } catch (e) {
      appendConsoleLog(raw);
    }
  }

  function appendConsoleLog(text) {
    if (!dom.consoleLogs) return;
    const cleanText = text.replace(/<[^>]+>/g, '');
    dom.consoleLogs.textContent += cleanText;
    dom.consoleLogs.scrollTop = dom.consoleLogs.scrollHeight;
  }

  function updateQueueBadge(count) {
    state.queueCount = count || 0;
    if (dom.queueCountBadge) {
      dom.queueCountBadge.textContent = state.queueCount;
      dom.queueCountBadge.style.display = state.queueCount > 0 ? 'inline-block' : 'none';
    }
  }

  function resetConvertingButtons() {
    document.querySelectorAll('[data-action="convert"]').forEach((btn) => {
      btn.disabled = false;
      btn.textContent = '轉檔';
    });
  }

  // =========================================================================
  // Data Loading & API Calls
  // =========================================================================
  async function loadSystemStatus() {
    try {
      const res = await fetch('/api/system/status');
      if (res.ok) {
        state.systemStatus = await res.json();
        if (dom.appVersionText) {
          dom.appVersionText.textContent = `v${state.systemStatus.narou_version} · 設備: ${state.systemStatus.device_name || state.systemStatus.device}`;
        }

        // 填入系統資訊頁籤
        const sysNarou = document.getElementById('sysNarouVer');
        const sysRuby = document.getElementById('sysRubyVer');
        const sysRoot = document.getElementById('sysRootDir');
        const sysOs = document.getElementById('sysOs');
        const sysCount = document.getElementById('sysNovelsCount');
        if (sysNarou) sysNarou.textContent = state.systemStatus.narou_version;
        if (sysRuby) sysRuby.textContent = state.systemStatus.ruby_version;
        if (sysRoot) sysRoot.textContent = state.systemStatus.root_dir;
        if (sysOs) sysOs.textContent = state.systemStatus.os;
        if (sysCount) sysCount.textContent = state.systemStatus.novels_count;

        // 若 AozoraEpub3 未就緒且沒有小說，主動跳出首次引導精靈
        if (!state.systemStatus.aozoraepub3_exists && state.systemStatus.novels_count === 0) {
          openWizardModal();
        }
      }
    } catch (e) {
      console.error('Failed to load system status:', e);
    }
  }

  async function loadNovelsList() {
    try {
      const res = await fetch('/api/list');
      if (res.ok) {
        const result = await res.json();
        state.novels = result.data || [];
        renderTagsCloud();
        renderNovels();
      }
    } catch (e) {
      console.error('Failed to load novels:', e);
      showToast('載入小說列表失敗，請檢查伺服器狀態', 'error');
    }
  }

  // =========================================================================
  // Rendering
  // =========================================================================
  function renderTagsCloud() {
    if (!dom.tagsCloud) return;
    const tagCountMap = {};
    state.novels.forEach((novel) => {
      const tags = (novel.tags || '').match(/data-tag="([^"]+)"/g) || [];
      tags.forEach((t) => {
        const tag = t.replace('data-tag="', '').replace('"', '');
        if (tag) tagCountMap[tag] = (tagCountMap[tag] || 0) + 1;
      });
    });

    const tags = Object.keys(tagCountMap).slice(0, 12);
    if (tags.length === 0) {
      dom.tagsCloud.style.display = 'none';
      return;
    }
    dom.tagsCloud.style.display = 'flex';

    dom.tagsCloud.innerHTML = `
      <span class="tags-title">常用標籤：</span>
      <span class="tag-badge ${state.activeTag === null ? 'active' : ''}" data-tag="">全部</span>
      ${tags
        .map(
          (tag) => `
        <span class="tag-badge ${state.activeTag === tag ? 'active' : ''}" data-tag="${tag}">
          ${tag} (${tagCountMap[tag]})
        </span>
      `
        )
        .join('')}
    `;

    dom.tagsCloud.querySelectorAll('.tag-badge').forEach((badge) => {
      badge.addEventListener('click', () => {
        const tag = badge.dataset.tag || null;
        state.activeTag = tag;
        renderTagsCloud();
        renderNovels();
      });
    });
  }

  function getFilteredNovels() {
    return state.novels.filter((novel) => {
      // 搜尋關鍵字
      if (state.searchKeyword) {
        const kw = state.searchKeyword.toLowerCase();
        const matchTitle = (novel.title || '').toLowerCase().includes(kw);
        const matchAuthor = (novel.author || '').toLowerCase().includes(kw);
        const matchId = (novel.id || '').toLowerCase().includes(kw);
        if (!matchTitle && !matchAuthor && !matchId) return false;
      }

      // 狀態篩選
      if (state.activeFilter === 'serializing' && novel.status && novel.status.includes('完結')) {
        return false;
      }
      if (state.activeFilter === 'completed' && (!novel.status || !novel.status.includes('完結'))) {
        return false;
      }
      if (state.activeFilter === 'frozen' && !novel.frozen) {
        return false;
      }

      // 標籤篩選
      if (state.activeTag && (!novel.tags || !novel.tags.includes(`data-tag="${state.activeTag}"`))) {
        return false;
      }

      return true;
    });
  }

  function formatDate(timestamp) {
    if (!timestamp) return '-';
    const date = new Date(timestamp * 1000);
    const y = date.getFullYear();
    const m = String(date.getMonth() + 1).padStart(2, '0');
    const d = String(date.getDate()).padStart(2, '0');
    return `${y}/${m}/${d}`;
  }

  function renderNovels() {
    const list = getFilteredNovels();

    if (list.length === 0) {
      if (dom.novelGridContainer) dom.novelGridContainer.style.display = 'none';
      if (dom.novelTableContainer) dom.novelTableContainer.style.display = 'none';
      if (dom.emptyState) dom.emptyState.style.display = 'flex';
      return;
    }

    if (dom.emptyState) dom.emptyState.style.display = 'none';

    if (state.currentView === 'grid') {
      if (dom.novelGridContainer) dom.novelGridContainer.style.display = 'grid';
      if (dom.novelTableContainer) dom.novelTableContainer.style.display = 'none';
      renderGrid(list);
    } else {
      if (dom.novelGridContainer) dom.novelGridContainer.style.display = 'none';
      if (dom.novelTableContainer) dom.novelTableContainer.style.display = 'block';
      renderTable(list);
    }

    updateBatchFloatingBar();
  }

  function renderGrid(list) {
    if (!dom.novelGridContainer) return;
    dom.novelGridContainer.innerHTML = list
      .map((novel) => {
        const isChecked = state.selectedIds.has(novel.id);
        return `
        <div class="novel-card ${novel.frozen ? 'frozen' : ''}" data-id="${novel.id}">
          <div>
            <div class="card-top">
              <span class="site-badge">${novel.sitename || '網路小說'}</span>
              <input type="checkbox" class="card-checkbox" data-id="${novel.id}" ${isChecked ? 'checked' : ''}>
            </div>
            <h3 class="novel-title" data-action="story" data-id="${novel.id}">${novel.title}</h3>
            <div class="novel-author">${novel.author || '未知作者'}</div>
            
            <div class="novel-meta-info">
              <span class="meta-item" title="總話數">
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H20v20H6.5a2.5 2.5 0 0 1-2.5-2.5Z"/></svg>
                ${novel.general_all_no || 0} 話
              </span>
              <span class="meta-item" title="最後更新時間">
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
                ${formatDate(novel.last_update)}
              </span>
              <span class="meta-item" style="color: ${novel.frozen ? 'var(--color-warning)' : 'inherit'}">
                ${novel.status || (novel.frozen ? '已鎖定' : '正常')}
              </span>
            </div>
          </div>

          <div class="card-actions">
            <div class="card-actions-left">
              <button class="btn btn-sm btn-outline" data-action="update" data-id="${novel.id}" title="更新最新章節">更新</button>
              <button class="btn btn-sm btn-outline btn-convert-novel" data-action="convert" data-id="${novel.id}" title="選擇語言並轉檔為電子書">轉檔</button>
              <a href="/novels/${novel.id}/download" class="btn btn-sm btn-ghost" title="下載已轉檔之電子書檔案">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/></svg>
              </a>
            </div>
            <div>
              <button class="btn btn-sm btn-ghost" data-action="freeze" data-id="${novel.id}" title="${novel.frozen ? '解除更新鎖定' : '鎖定更新'}">
                ${novel.frozen ? '解鎖' : '鎖定'}
              </button>
            </div>
          </div>
        </div>
      `;
      })
      .join('');

    bindNovelEvents(dom.novelGridContainer);
  }

  function renderTable(list) {
    if (!dom.novelTableBody) return;
    dom.novelTableBody.innerHTML = list
      .map((novel) => {
        const isChecked = state.selectedIds.has(novel.id);
        return `
        <tr data-id="${novel.id}">
          <td><input type="checkbox" class="card-checkbox" data-id="${novel.id}" ${isChecked ? 'checked' : ''}></td>
          <td><code>${novel.id}</code></td>
          <td>
            <strong class="novel-title" data-action="story" data-id="${novel.id}" style="cursor: pointer;">${novel.title}</strong>
            <div style="font-size: 11px; color: var(--color-text-sub);">${novel.sitename || ''}</div>
          </td>
          <td>${novel.author || '-'}</td>
          <td>${novel.general_all_no || 0}</td>
          <td><span style="color: ${novel.frozen ? 'var(--color-warning)' : 'inherit'}">${novel.status || (novel.frozen ? '鎖定' : '正常')}</span></td>
          <td style="font-size: 12px; color: var(--color-text-muted);">${cleanTagsText(novel.tags)}</td>
          <td>${formatDate(novel.last_update)}</td>
          <td style="text-align: right;">
            <button class="btn btn-sm btn-outline" data-action="update" data-id="${novel.id}">更新</button>
            <button class="btn btn-sm btn-outline btn-convert-novel" data-action="convert" data-id="${novel.id}">轉檔</button>
            <a href="/novels/${novel.id}/download" class="btn btn-sm btn-ghost" title="下載電子書">
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/></svg>
            </a>
          </td>
        </tr>
      `;
      })
      .join('');

    bindNovelEvents(dom.novelTableBody);
  }

  function cleanTagsText(tagsHtml) {
    if (!tagsHtml) return '-';
    const div = document.createElement('div');
    div.innerHTML = tagsHtml;
    return div.textContent.trim().replace(/\s+/g, ' ') || '-';
  }

  function bindNovelEvents(container) {
    // Checkboxes
    container.querySelectorAll('.card-checkbox').forEach((cb) => {
      cb.addEventListener('change', (e) => {
        const id = e.target.dataset.id;
        if (e.target.checked) {
          state.selectedIds.add(id);
        } else {
          state.selectedIds.delete(id);
        }
        updateBatchFloatingBar();
      });
    });

    // Action buttons
    container.querySelectorAll('[data-action]').forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        const action = btn.dataset.action;
        const id = btn.dataset.id;

        if (action === 'update') triggerUpdate(id);
        if (action === 'convert') openConvertModal([id]);
        if (action === 'freeze') triggerFreezeToggle(id);
        if (action === 'story') openStoryModal(id);
      });
    });
  }

  // =========================================================================
  // Convert Modal & Logic (選擇翻譯 / 原版)
  // =========================================================================
  function openConvertModal(ids) {
    state.pendingConvertIds = Array.isArray(ids) ? ids : [ids];
    const targetTitleEl = document.getElementById('convertTargetTitle');
    const noticeEl = document.getElementById('convertCurrentModelNotice');

    if (state.pendingConvertIds.length === 1) {
      const novel = state.novels.find((n) => n.id === state.pendingConvertIds[0]);
      if (targetTitleEl) targetTitleEl.textContent = novel ? novel.title : `小說 ID: ${state.pendingConvertIds[0]}`;
    } else {
      if (targetTitleEl) targetTitleEl.textContent = `已選擇 ${state.pendingConvertIds.length} 部小說進行批次轉檔`;
    }

    if (noticeEl && state.systemStatus) {
      const engine = state.systemStatus.translate_engine || 'openai';
      const model = state.systemStatus.translate_model || 'sakura-best';
      noticeEl.textContent = `目前設定：引擎 ${engine.toUpperCase()} / 模型 ${model}`;
    }

    // 預設選項依據 systemStatus
    const defaultTranslate = state.systemStatus && state.systemStatus.translate_enable;
    const radios = document.getElementsByName('convertTranslateOption');
    radios.forEach((r) => {
      if (r.value === (defaultTranslate ? 'true' : 'false')) r.checked = true;
    });

    dom.convertModal.classList.add('open');
  }

  async function submitConvert() {
    const ids = state.pendingConvertIds;
    if (ids.length === 0) return;

    const radios = document.getElementsByName('convertTranslateOption');
    let translate = 'false';
    radios.forEach((r) => {
      if (r.checked) translate = r.value;
    });
    const retranslateCheck = document.getElementById('convertRetranslateCheck');
    const retranslate = retranslateCheck && retranslateCheck.checked ? 'true' : 'false';

    dom.convertModal.classList.remove('open');
    dom.consoleDrawer.classList.add('open'); // 自動打開日誌抽屜

    // 按鈕動態 loading 反饋
    ids.forEach((id) => {
      const btn = document.querySelector(`[data-id="${id}"] .btn-convert-novel`);
      if (btn) {
        btn.disabled = true;
        btn.textContent = '轉檔中...';
      }
    });

    showToast(`已啟動轉檔（模式：${translate === 'true' ? 'AI 繁體中文翻譯' : '日文原版'}）`, 'info');

    try {
      const res = await fetch('/api/convert', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: `ids=${ids.join(' ')}&translate=${translate}&retranslate=${retranslate}`,
      });
      if (res.ok) {
        // 等待 WebSocket 推播結果或背景完成
      } else {
        showToast('轉檔請求失敗', 'error');
        resetConvertingButtons();
      }
    } catch (e) {
      showToast('轉檔失敗，請確認伺服器連線', 'error');
      resetConvertingButtons();
    }
  }

  // =========================================================================
  // Batch Operations & Floating Bar
  // =========================================================================
  function updateBatchFloatingBar() {
    const count = state.selectedIds.size;
    if (dom.batchCountText) dom.batchCountText.textContent = `已選取 ${count} 部小說`;

    if (count > 0) {
      dom.batchFloatingBar.classList.add('show');
    } else {
      dom.batchFloatingBar.classList.remove('show');
    }

    if (dom.selectAllCheckbox) {
      const filtered = getFilteredNovels();
      dom.selectAllCheckbox.checked = filtered.length > 0 && count === filtered.length;
    }
  }

  async function triggerBatchAction(action) {
    const ids = Array.from(state.selectedIds);
    if (ids.length === 0) return;

    if (action === 'convert') {
      openConvertModal(ids);
      return;
    }

    try {
      const res = await fetch('/api/novels/batch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action, ids }),
      });
      if (res.ok) {
        showToast(`已成功將 ${ids.length} 部小說加入「${action}」佇列`, 'success');
        state.selectedIds.clear();
        updateBatchFloatingBar();
        renderNovels();
      }
    } catch (e) {
      showToast('批次作業執行失敗', 'error');
    }
  }

  // =========================================================================
  // Individual Novel Operations
  // =========================================================================
  async function triggerUpdate(id) {
    try {
      const res = await fetch('/api/update', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: `ids=${id}`,
      });
      if (res.ok) {
        showToast('已加入更新佇列', 'success');
        dom.consoleDrawer.classList.add('open');
      }
    } catch (e) {
      showToast('更新失敗', 'error');
    }
  }

  async function triggerFreezeToggle(id) {
    const novel = state.novels.find((n) => n.id === id);
    const endpoint = novel && novel.frozen ? '/api/freeze_off' : '/api/freeze_on';
    try {
      const res = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: `ids=${id}`,
      });
      if (res.ok) {
        showToast(novel && novel.frozen ? '已解除鎖定' : '已鎖定更新', 'success');
        loadNovelsList();
      }
    } catch (e) {
      showToast('設定更新鎖定失敗', 'error');
    }
  }

  async function openStoryModal(id) {
    const novel = state.novels.find((n) => n.id === id);
    const titleEl = document.getElementById('detailModalTitle');
    const authorEl = document.getElementById('detailAuthorInfo');
    const siteEl = document.getElementById('detailSiteInfo');
    const storyEl = document.getElementById('detailStoryContent');
    const linkEl = document.getElementById('detailOpenOriginalLink');

    if (titleEl) titleEl.textContent = novel ? novel.title : '小說大綱';
    if (authorEl) authorEl.textContent = `作者：${novel ? novel.author : '未知'}`;
    if (siteEl) siteEl.textContent = `來源網站：${novel ? novel.sitename : '未知'}`;
    if (storyEl) storyEl.textContent = '載入故事大綱中...';
    if (linkEl && novel) linkEl.href = novel.toc_url || '#';

    dom.detailModal.classList.add('open');

    try {
      const res = await fetch(`/api/story?id=${id}`);
      if (res.ok) {
        const data = await res.json();
        if (storyEl) storyEl.innerHTML = data.story || '原站未提供大綱。';
      }
    } catch (e) {
      if (storyEl) storyEl.textContent = '讀取大綱失敗。';
    }
  }

  // =========================================================================
  // Download Modal & Submissions
  // =========================================================================
  async function submitDownload() {
    const urlInput = document.getElementById('downloadUrlInput');
    const autoConvert = document.getElementById('downloadAutoConvert');
    const autoMail = document.getElementById('downloadAutoMail');

    const urls = (urlInput ? urlInput.value : '')
      .split('\n')
      .map((u) => u.trim())
      .filter((u) => u.length > 0);

    if (urls.length === 0) {
      showToast('請先貼上至少一個小說網址', 'warning');
      return;
    }

    try {
      const res = await fetch('/api/download', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: `targets=${encodeURIComponent(urls.join(' '))}&mail=${autoMail && autoMail.checked ? 'true' : 'false'}`,
      });

      if (res.ok) {
        showToast(`已成功將 ${urls.length} 部小說加入下載佇列！`, 'success');
        dom.downloadModal.classList.remove('open');
        if (urlInput) urlInput.value = '';
        dom.consoleDrawer.classList.add('open');
      }
    } catch (e) {
      showToast('加入下載佇列失敗', 'error');
    }
  }

  // =========================================================================
  // Setup Wizard & System Settings
  // =========================================================================
  function openWizardModal() {
    state.wizardStep = 1;
    updateWizardUI();
    dom.wizardModal.classList.add('open');
  }

  function updateWizardUI() {
    const s1 = document.getElementById('stepIndicator1');
    const s2 = document.getElementById('stepIndicator2');
    const s3 = document.getElementById('stepIndicator3');
    const c1 = document.getElementById('wizardStep1Content');
    const c2 = document.getElementById('wizardStep2Content');
    const c3 = document.getElementById('wizardStep3Content');
    const prevBtn = document.getElementById('btnWizardPrev');
    const nextBtn = document.getElementById('btnWizardNext');

    if (s1 && s2 && s3) {
      s1.className = `wizard-step ${state.wizardStep === 1 ? 'active' : state.wizardStep > 1 ? 'done' : ''}`;
      s2.className = `wizard-step ${state.wizardStep === 2 ? 'active' : state.wizardStep > 2 ? 'done' : ''}`;
      s3.className = `wizard-step ${state.wizardStep === 3 ? 'active' : state.wizardStep > 3 ? 'done' : ''}`;
    }

    if (c1) c1.style.display = state.wizardStep === 1 ? 'block' : 'none';
    if (c2) c2.style.display = state.wizardStep === 2 ? 'block' : 'none';
    if (c3) c3.style.display = state.wizardStep === 3 ? 'block' : 'none';

    if (prevBtn) prevBtn.style.display = state.wizardStep > 1 ? 'inline-flex' : 'none';
    if (nextBtn) nextBtn.textContent = state.wizardStep === 3 ? '完成設定並開始使用' : '下一步';

    // 填入偵測路徑
    if (state.wizardStep === 2 && state.systemStatus) {
      const aozoraInput = document.getElementById('wizardAozoraPath');
      const aozoraStatus = document.getElementById('wizardAozoraStatus');
      if (aozoraInput && state.systemStatus.aozoraepub3_dir) {
        aozoraInput.value = state.systemStatus.aozoraepub3_dir;
      }
      if (aozoraStatus) {
        aozoraStatus.textContent = state.systemStatus.aozoraepub3_exists
          ? '✓ 已在預設路徑偵測到 AozoraEpub3！'
          : '請指定 AozoraEpub3 解壓縮目錄。';
      }
    }
  }

  async function handleWizardNext() {
    if (state.wizardStep < 3) {
      state.wizardStep++;
      updateWizardUI();
    } else {
      const device = document.getElementById('wizardDeviceSelect').value;
      const aozoraDir = document.getElementById('wizardAozoraPath').value;
      const lineHeight = document.getElementById('wizardLineHeight').value;

      try {
        const res = await fetch('/api/system/setup', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            device,
            aozoraepub3_dir: aozoraDir,
            line_height: lineHeight,
          }),
        });
        if (res.ok) {
          showToast('首次引導設定完成！歡迎使用 Narou 小說管理器', 'success');
          dom.wizardModal.classList.remove('open');
          loadSystemStatus();
        }
      } catch (e) {
        showToast('儲存設定失敗', 'error');
      }
    }
  }

  // =========================================================================
  // Settings Center Modal (含 AI 模型設置)
  // =========================================================================
  function openSettingsModal() {
    if (state.systemStatus) {
      const devSelect = document.getElementById('settingDevice');
      const aozoraInput = document.getElementById('settingAozoraDir');
      const aozoraStatus = document.getElementById('settingAozoraStatusText');
      const kindlegenInput = document.getElementById('settingKindlegenPath');
      const lineInput = document.getElementById('settingLineHeight');

      // AI 翻譯相關控制項
      const trEnable = document.getElementById('settingTranslateEnable');
      const trEngine = document.getElementById('settingTranslateEngine');
      const trApiKey = document.getElementById('settingTranslateApiKey');
      const trModel = document.getElementById('settingTranslateModel');
      const trEndpoint = document.getElementById('settingTranslateEndpoint');

      if (devSelect) devSelect.value = state.systemStatus.device || 'epub';
      if (aozoraInput) aozoraInput.value = state.systemStatus.aozoraepub3_dir || '';
      if (aozoraStatus) {
        aozoraStatus.textContent = state.systemStatus.aozoraepub3_exists
          ? '✓ AozoraEpub3 正常運作中'
          : '⚠️ 尚未偵測到 AozoraEpub3.jar，請確認目錄路徑';
      }
      if (kindlegenInput) kindlegenInput.value = state.systemStatus.kindlegen_path || '';
      if (lineInput) lineInput.value = state.systemStatus.line_height || 1.8;

      if (trEnable) trEnable.checked = !!state.systemStatus.translate_enable;
      if (trEngine) trEngine.value = state.systemStatus.translate_engine || 'openai';
      if (trApiKey) trApiKey.value = state.systemStatus.translate_api_key || '';
      if (trModel) trModel.value = state.systemStatus.translate_model || 'sakura-best';
      if (trEndpoint) trEndpoint.value = state.systemStatus.translate_endpoint || 'http://localhost:11434/v1';
    }
    const testResultEl = document.getElementById('translateTestResult');
    if (testResultEl) testResultEl.textContent = '';

    dom.settingsModal.classList.add('open');
  }

  async function saveSettings() {
    const device = document.getElementById('settingDevice').value;
    const aozoraDir = document.getElementById('settingAozoraDir').value;
    const lineHeight = document.getElementById('settingLineHeight').value;

    const translate_enable = document.getElementById('settingTranslateEnable').checked;
    const translate_engine = document.getElementById('settingTranslateEngine').value;
    const translate_api_key = document.getElementById('settingTranslateApiKey').value;
    const translate_model = document.getElementById('settingTranslateModel').value;
    const translate_endpoint = document.getElementById('settingTranslateEndpoint').value;

    try {
      const res = await fetch('/api/system/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          device,
          aozoraepub3_dir: aozoraDir,
          line_height: lineHeight,
          translate_enable,
          translate_engine,
          translate_api_key,
          translate_model,
          translate_endpoint,
        }),
      });
      if (res.ok) {
        showToast('環境與 AI 翻譯設定已成功儲存！', 'success');
        dom.settingsModal.classList.remove('open');
        loadSystemStatus();
      }
    } catch (e) {
      showToast('儲存設定失敗', 'error');
    }
  }

  async function testTranslateConnection() {
    const testResultEl = document.getElementById('translateTestResult');
    const testBtn = document.getElementById('btnTestTranslate');
    const engine = document.getElementById('settingTranslateEngine').value;
    const api_key = document.getElementById('settingTranslateApiKey').value;
    const model = document.getElementById('settingTranslateModel').value;
    const endpoint = document.getElementById('settingTranslateEndpoint').value;

    if (testBtn) testBtn.disabled = true;
    if (testResultEl) {
      testResultEl.style.color = 'var(--color-primary)';
      testResultEl.textContent = '⚡ 連線測試中（本地模型初次載入需約 10~15 秒，請稍候）...';
    }

    try {
      const res = await fetch('/api/translate/test', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ engine, api_key, model, endpoint }),
      });
      const data = await res.json();
      if (data.success) {
        testResultEl.style.color = 'var(--color-success)';
        testResultEl.textContent = `✓ 測試成功！[${data.duration || '完成'}] 日文「${data.source}」→「${data.translated}」`;
      } else {
        testResultEl.style.color = 'var(--color-danger)';
        testResultEl.textContent = `❌ 測試失敗：${data.error}`;
      }
    } catch (e) {
      if (testResultEl) {
        testResultEl.style.color = 'var(--color-danger)';
        testResultEl.textContent = '❌ 連線測試發生異常，請確認端點 URL 或網路狀態。';
      }
    } finally {
      if (testBtn) testBtn.disabled = false;
    }
  }

  // =========================================================================
  // Event Bindings
  // =========================================================================
  function bindEvents() {
    // Theme
    if (dom.btnToggleTheme) dom.btnToggleTheme.addEventListener('click', toggleTheme);

    // Search
    if (dom.searchInput) {
      dom.searchInput.addEventListener('input', (e) => {
        state.searchKeyword = e.target.value.trim();
        renderNovels();
      });
    }

    // Status Filters
    document.querySelectorAll('.filter-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('.filter-btn').forEach((b) => b.classList.remove('active'));
        btn.classList.add('active');
        state.activeFilter = btn.dataset.filter;
        renderNovels();
      });
    });

    // View Toggle
    if (dom.viewBtnGrid && dom.viewBtnList) {
      dom.viewBtnGrid.addEventListener('click', () => {
        state.currentView = 'grid';
        localStorage.setItem('narou_view_mode', 'grid');
        dom.viewBtnGrid.classList.add('active');
        dom.viewBtnList.classList.remove('active');
        renderNovels();
      });
      dom.viewBtnList.addEventListener('click', () => {
        state.currentView = 'list';
        localStorage.setItem('narou_view_mode', 'list');
        dom.viewBtnList.classList.add('active');
        dom.viewBtnGrid.classList.remove('active');
        renderNovels();
      });
    }

    // Select All Checkbox
    if (dom.selectAllCheckbox) {
      dom.selectAllCheckbox.addEventListener('change', (e) => {
        const filtered = getFilteredNovels();
        if (e.target.checked) {
          filtered.forEach((n) => state.selectedIds.add(n.id));
        } else {
          state.selectedIds.clear();
        }
        renderNovels();
      });
    }

    // Batch Actions
    const btnBatchUpdate = document.getElementById('btnBatchUpdate');
    const btnBatchConvert = document.getElementById('btnBatchConvert');
    const btnBatchSend = document.getElementById('btnBatchSend');
    const btnBatchFreeze = document.getElementById('btnBatchFreeze');
    const btnBatchDelete = document.getElementById('btnBatchDelete');
    const btnCancelBatch = document.getElementById('btnCancelBatch');

    if (btnBatchUpdate) btnBatchUpdate.addEventListener('click', () => triggerBatchAction('update'));
    if (btnBatchConvert) btnBatchConvert.addEventListener('click', () => triggerBatchAction('convert'));
    if (btnBatchSend) btnBatchSend.addEventListener('click', () => triggerBatchAction('send'));
    if (btnBatchFreeze) btnBatchFreeze.addEventListener('click', () => triggerBatchAction('freeze_on'));
    if (btnBatchDelete) {
      btnBatchDelete.addEventListener('click', () => {
        if (confirm(`確定要刪除選取的 ${state.selectedIds.size} 部小說嗎？（小說檔案將一併移除）`)) {
          triggerBatchAction('remove_with_file');
        }
      });
    }
    if (btnCancelBatch) {
      btnCancelBatch.addEventListener('click', () => {
        state.selectedIds.clear();
        renderNovels();
      });
    }

    // Update All
    if (dom.btnUpdateAll) {
      dom.btnUpdateAll.addEventListener('click', async () => {
        try {
          const res = await fetch('/api/update', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: '',
          });
          if (res.ok) {
            showToast('已啟動全部小說更新檢查', 'success');
            dom.consoleDrawer.classList.add('open');
          }
        } catch (e) {
          showToast('啟動更新失敗', 'error');
        }
      });
    }

    // Convert Modal Actions
    const btnCloseConvertModal = document.getElementById('btnCloseConvertModal');
    const btnCancelConvert = document.getElementById('btnCancelConvert');
    const btnSubmitConvert = document.getElementById('btnSubmitConvert');
    if (btnCloseConvertModal) btnCloseConvertModal.addEventListener('click', () => dom.convertModal.classList.remove('open'));
    if (btnCancelConvert) btnCancelConvert.addEventListener('click', () => dom.convertModal.classList.remove('open'));
    if (btnSubmitConvert) btnSubmitConvert.addEventListener('click', submitConvert);

    // Download Modal Actions
    if (dom.btnOpenDownloadModal) {
      dom.btnOpenDownloadModal.addEventListener('click', () => {
        dom.downloadModal.classList.add('open');
      });
    }
    const btnCloseDownloadModal = document.getElementById('btnCloseDownloadModal');
    const btnCancelDownload = document.getElementById('btnCancelDownload');
    const btnSubmitDownload = document.getElementById('btnSubmitDownload');
    if (btnCloseDownloadModal) btnCloseDownloadModal.addEventListener('click', () => dom.downloadModal.classList.remove('open'));
    if (btnCancelDownload) btnCancelDownload.addEventListener('click', () => dom.downloadModal.classList.remove('open'));
    if (btnSubmitDownload) btnSubmitDownload.addEventListener('click', submitDownload);

    // Empty state actions
    const btnEmptyDownload = document.getElementById('btnEmptyDownload');
    const btnEmptySetup = document.getElementById('btnEmptySetup');
    if (btnEmptyDownload) btnEmptyDownload.addEventListener('click', () => dom.downloadModal.classList.add('open'));
    if (btnEmptySetup) btnEmptySetup.addEventListener('click', openWizardModal);

    // Detail Modal Actions
    const btnCloseDetailModal = document.getElementById('btnCloseDetailModal');
    const btnCloseDetailBtn = document.getElementById('btnCloseDetailBtn');
    if (btnCloseDetailModal) btnCloseDetailModal.addEventListener('click', () => dom.detailModal.classList.remove('open'));
    if (btnCloseDetailBtn) btnCloseDetailBtn.addEventListener('click', () => dom.detailModal.classList.remove('open'));

    // Console Drawer
    if (dom.btnToggleConsole) {
      dom.btnToggleConsole.addEventListener('click', () => {
        dom.consoleDrawer.classList.toggle('open');
      });
    }
    const btnCloseConsole = document.getElementById('btnCloseConsole');
    const btnClearConsole = document.getElementById('btnClearConsole');
    const btnCopyConsole = document.getElementById('btnCopyConsole');
    if (btnCloseConsole) btnCloseConsole.addEventListener('click', () => dom.consoleDrawer.classList.remove('open'));
    if (btnClearConsole) btnClearConsole.addEventListener('click', () => { dom.consoleLogs.textContent = ''; });
    if (btnCopyConsole) {
      btnCopyConsole.addEventListener('click', () => {
        navigator.clipboard.writeText(dom.consoleLogs.textContent);
        showToast('日誌已複製至剪貼簿', 'info');
      });
    }

    // Wizard Modal Actions
    const btnCloseWizard = document.getElementById('btnCloseWizard');
    const btnWizardPrev = document.getElementById('btnWizardPrev');
    const btnWizardNext = document.getElementById('btnWizardNext');
    if (btnCloseWizard) btnCloseWizard.addEventListener('click', () => dom.wizardModal.classList.remove('open'));
    if (btnWizardPrev) {
      btnWizardPrev.addEventListener('click', () => {
        if (state.wizardStep > 1) {
          state.wizardStep--;
          updateWizardUI();
        }
      });
    }
    if (btnWizardNext) btnWizardNext.addEventListener('click', handleWizardNext);

    // Settings Modal Actions
    if (dom.btnOpenSettingsModal) dom.btnOpenSettingsModal.addEventListener('click', openSettingsModal);
    const btnCloseSettingsModal = document.getElementById('btnCloseSettingsModal');
    const btnCancelSettings = document.getElementById('btnCancelSettings');
    const btnSaveSettings = document.getElementById('btnSaveSettings');
    if (btnCloseSettingsModal) btnCloseSettingsModal.addEventListener('click', () => dom.settingsModal.classList.remove('open'));
    if (btnCancelSettings) btnCancelSettings.addEventListener('click', () => dom.settingsModal.classList.remove('open'));
    if (btnSaveSettings) btnSaveSettings.addEventListener('click', saveSettings);

    // Settings Tabs
    document.querySelectorAll('.tab-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('.tab-btn').forEach((b) => b.classList.remove('active'));
        document.querySelectorAll('.tab-content').forEach((c) => c.classList.remove('active'));
        btn.classList.add('active');
        const content = document.getElementById(btn.dataset.tab);
        if (content) content.classList.add('active');
      });
    });

    // AI 翻譯快捷按鈕
    document.querySelectorAll('.btn-quick-model').forEach((btn) => {
      btn.addEventListener('click', () => {
        const modelInput = document.getElementById('settingTranslateModel');
        if (modelInput) modelInput.value = btn.dataset.model;
      });
    });

    document.querySelectorAll('.btn-quick-endpoint').forEach((btn) => {
      btn.addEventListener('click', () => {
        const epInput = document.getElementById('settingTranslateEndpoint');
        if (epInput) epInput.value = btn.dataset.endpoint;
      });
    });

    const btnToggleApiKey = document.getElementById('btnToggleApiKeyVisibility');
    if (btnToggleApiKey) {
      btnToggleApiKey.addEventListener('click', () => {
        const keyInput = document.getElementById('settingTranslateApiKey');
        if (keyInput) {
          const isPwd = keyInput.type === 'password';
          keyInput.type = isPwd ? 'text' : 'password';
          btnToggleApiKey.textContent = isPwd ? '隱藏' : '顯示';
        }
      });
    }

    const btnTestTranslate = document.getElementById('btnTestTranslate');
    if (btnTestTranslate) btnTestTranslate.addEventListener('click', testTranslateConnection);

    // Close modals on backdrop click
    document.querySelectorAll('.modal-backdrop').forEach((backdrop) => {
      backdrop.addEventListener('click', (e) => {
        if (e.target === backdrop) backdrop.classList.remove('open');
      });
    });
  }

  // =========================================================================
  // Bootstrap Application
  // =========================================================================
  function init() {
    initTheme();
    bindEvents();
    initWebSocket();
    loadSystemStatus();
    loadNovelsList();
  }

  document.addEventListener('DOMContentLoaded', init);
})();
