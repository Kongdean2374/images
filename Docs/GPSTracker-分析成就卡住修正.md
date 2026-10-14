# 分析、成就與重新開啟卡住修正

使用者症狀：進入分析／成就後，整個畫面及底部分頁皆不回應；強制結束後重新開啟，有時不確定是否正在恢復。

原始碼確認的阻塞路徑：

- AnalyticsView.onAppear 同步執行路線分群、最佳分段與資料完整性；會在主執行緒 fault／排序歷史 GPS 點。
- PBDashboardView.onAppear 同步遍歷軌跡；AchievementsView 的多個 computed property 每次 body 重繪都重跑整份徽章計算。
- RootView.onAppear 與 DiagnosticsLog.checkPreviousRun 各自同步讀取、解碼完整運動 JSON。
- 暫存寫入排在背景佇列，但清除直接在前景刪檔，可能被較早的排隊寫入重新建立；接續時還會先清除最後一份存檔。

修改：

- 背景 ModelActor 計算路線、分段、徽章、品質報告；UI 僅接收值型別結果，不跨執行緒傳遞 SwiftData model。
- 路線分群僅查起終點；最佳分段逐場用短生命週期 context 讀取，原始路線完全保留。沿用最新 200 場最佳分段的既有範圍，沒有截斷任何原始點。
- 分析／成就／徽章共用結果快取；資料保存事件 debounce 後失效，離開頁面取消計算，舊 generation 的結果不套用。提供載入進度與失敗重試。
- 只在選中分析／成就分頁時建立相關畫面，啟動不預先運算所有歷史路線。
- 初始化完成後，運動暫存只讀一次，背景解碼並提供「正在檢查上次記錄」狀態；過期或無法解碼的原始檔不自動刪除。
- 暫存保存／讀取／清除共用序列佇列，防止清除後被舊寫入復活。接續保留最後存檔，先關閉恢復 sheet 再開記錄畫面。
- 恢復存檔改用背景 ModelActor，保留全部 GPS 精度與位置。運動 UUID 納入新暫存，舊暫存使用穩定恢復識別，重試不重複新增；確認資料庫保存才清除暫存。健康同步仍保留，且不阻塞恢復畫面。
- 不重建／清空資料庫，不改原始歷史或把恢復的未知距離升級成訓練真值。

驗證入口：

```sh
swift test
python3 Scripts/test_portable_integration.py
# Requires macOS SwiftData SDK; uses only an in-memory synthetic database.
python3 Scripts/test_swiftdata_background.py
```

本機 31 個核心／恢復／大型資料測試通過；可攜式實際來源整合檢查包含舊版暫存與 7,001 個完整 GPS 點恢復、穩定 UUID、未知來源不參與訓練。雲端流程另執行原生 SwiftData 背景 reader 測試及真正 iOS Archive，結果以該次 Actions 記錄為準。

尚需同一支 iPhone、同一份歷史資料實測：分析／成就切換、計算時切頁、強制結束後重啟、接續／直接保存、鎖屏與記憶體壓力。原始碼阻塞路徑修正與建置成功不能替代實機確認。
