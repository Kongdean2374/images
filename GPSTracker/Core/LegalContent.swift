import Foundation

/// App 內的法務與說明文件。全部內建於 App，不需連線。
enum LegalContent {

    struct Section: Identifiable {
        let id = UUID()
        let heading: String
        let body: String
    }

    static let version = "1.4"
    static let effectiveDate = "2026 年 9 月 15 日"
    static let effectiveDateEN = "15 September 2026"
    static let appName = "GPS 軌跡記錄器"
    static let appNameEN = "GPS Trail Tracker"

    // MARK: - 權限一覽（圖示卡用）

    struct Permission: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let titleEN: String
        let purpose: String
        let purposeEN: String
        let required: Bool
    }

    static let permissions: [Permission] = [
        Permission(icon: "location.fill",
                   title: "定位（使用期間）",
                   titleEN: "Location (While Using)",
                   purpose: "記錄 GPS 路跑與健行的軌跡、距離、配速與海拔。",
                   purposeEN: "Records your route, distance, pace and elevation for outdoor runs and hikes.",
                   required: false),
        Permission(icon: "location.circle.fill",
                   title: "定位（永遠允許）",
                   titleEN: "Location (Always)",
                   purpose: "螢幕鎖定或 App 進入背景時，仍能持續記錄軌跡不中斷。",
                   purposeEN: "Keeps recording your route when the screen is locked or the app is in the background.",
                   required: false),
        Permission(icon: "figure.walk.motion",
                   title: "動作與健身",
                   titleEN: "Motion & Fitness",
                   purpose: "讀取計步器的步數、步頻、樓層與動作型態，用於無定位模式；並讀取氣壓計估算爬升。",
                   purposeEN: "Reads step count, cadence, floors and activity type from the motion sensors for the no-GPS modes, and barometric altitude for elevation gain.",
                   required: false),
        Permission(icon: "heart.fill",
                   title: "健康（讀取）",
                   titleEN: "Health (Read)",
                   purpose: "讀取體重、身高、步數、步行跑步距離、爬樓層、活動能量、體能訓練與心率，用於熱量估算、步幅校正與匯入歷史紀錄。",
                   purposeEN: "Reads body mass, height, steps, walking + running distance, flights climbed, active energy, workouts and heart rate for calorie estimates, stride calibration and importing your history.",
                   required: false),
        Permission(icon: "arrow.up.heart.fill",
                   title: "健康（寫入）",
                   titleEN: "Health (Write)",
                   purpose: "把你在本 App 完成的訓練寫成「體能訓練」，包含距離、消耗能量、爬樓層與 GPS 路線。",
                   purposeEN: "Saves workouts you complete here as Health workouts, including distance, active energy, flights climbed and the GPS route.",
                   required: false),
        Permission(icon: "bell.badge.fill",
                   title: "通知",
                   titleEN: "Notifications",
                   purpose: "每日步數與距離達標提醒、連續天數提醒、久坐提醒，以及背景匯入完成通知。",
                   purposeEN: "Daily step and distance goal alerts, streak reminders, sedentary reminders and background import notices.",
                   required: false),
        Permission(icon: "photo.on.rectangle",
                   title: "加入相簿",
                   titleEN: "Add to Photos",
                   purpose: "當你選擇把運動戰績卡片存成圖片時使用。",
                   purposeEN: "Used only when you choose to save a workout summary card as an image.",
                   required: false)
    ]

    // MARK: - 隱私政策（中文）

    static let privacyZH: [Section] = [
        Section(heading: "一、總則",
                body: """
                \(appName)（以下稱「本 App」）是一款完全在你的裝置上運作的運動記錄工具。本 App 沒有後端伺服器、不需要註冊帳號、不會將你的任何資料上傳到開發者或第三方。

                本 App 不含任何網路同步功能。所有資料只存在你的手機裡，要不要備份、備份到哪裡，完全由你自己決定（見第九節）。

                本政策說明本 App 會存取哪些資料、為什麼需要、存放在哪裡，以及你可以如何控制。本政策自 \(effectiveDate) 起生效，適用版本 \(version)。
                """),
        Section(heading: "二、我們不收集的資料",
                body: """
                本 App 不會收集、傳輸或販售下列任何資料：

                • 姓名、電子郵件、電話、生日等可識別個人身分的資料
                • 廣告識別碼（IDFA）、裝置識別碼或任何追蹤識別碼
                • 使用行為分析、當機回報或遙測資料
                • 你的運動紀錄、位置軌跡與健康資料

                本 App 不含任何第三方 SDK、廣告網路或分析工具，也沒有任何對外的網路連線需求。
                """),
        Section(heading: "三、本 App 存取的資料與用途",
                body: """
                以下資料僅在你授權後於裝置本機處理：

                1. 位置資料：僅在你主動開始 GPS 模式時記錄，用於計算軌跡、距離、配速與海拔。你若選擇「永遠允許」，是為了在螢幕鎖定或 App 進入背景時不中斷記錄。記錄結束後軌跡儲存在裝置本機。

                2. 動作與健身資料：步數、步頻、爬樓層、加速度計與陀螺儀讀值、氣壓計相對高度、動作型態（靜止／走路／跑步／騎車／交通工具）。用於無定位模式的距離估算、原地運動計次與走跑分段。

                3. 健康資料（HealthKit）：在你授權後讀取體重、身高、步數、步行跑步距離、爬樓層、活動能量、體能訓練紀錄與心率；並在你開啟時寫入你的訓練。健康資料僅在裝置本機使用，絕不會離開你的裝置。

                4. 你自行輸入的資料：體重、每日目標、天氣標記、自覺強度、備註、自訂動作與測驗標準。
                """),
        Section(heading: "四、健康資料的特別聲明",
                body: """
                依據 Apple 的規範，我們明確聲明：

                • 本 App 不會將 HealthKit 取得的任何資料用於廣告、行銷或類似用途
                • 本 App 不會將 HealthKit 資料揭露、販售或分享給任何第三方
                • 本 App 不會將 HealthKit 資料用於本政策所述以外的目的
                • 你可以隨時在 iOS「設定 → 隱私權與安全性 → 健康」中撤銷授權，撤銷後本 App 的其他功能仍可正常使用
                """),
        Section(heading: "五、資料儲存與安全",
                body: """
                所有運動紀錄、軌跡點、設定與校正資料，皆以 SwiftData 儲存在你裝置的 App 專屬沙盒中，受 iOS 檔案保護機制保護。本 App 未使用 iCloud 同步，因此資料不會離開這台裝置。

                你透過「匯出」功能產生的 CSV、GPX、TCX 或 PDF 檔案，會交由你選擇的分享方式處理；一旦你將檔案分享給其他 App 或服務，該資料即受對方的隱私政策規範。
                """),
        Section(heading: "六、你的控制權",
                body: """
                • 每一項權限都可以拒絕，拒絕後相關功能會自動停用或降級，其餘功能不受影響
                • 定位權限被拒絕時，計圈、間歇、原地運動、體能測驗與手動輸入等模式仍可完整使用
                • 你可以在「設定 → 資料」中匯出全部資料，或一鍵刪除所有紀錄
                • 刪除本 App 即會一併移除所有本機資料；已寫入健康 App 的紀錄需在健康 App 中另行刪除
                """),
        Section(heading: "七、兒童隱私",
                body: """
                本 App 並非針對 13 歲以下兒童設計，且不會在知情的情況下收集兒童的個人資料。由於本 App 不收集任何個人資料，亦不具備帳號或社群功能。
                """),
        Section(heading: "八、政策變更與聯絡方式",
                body: """
                本政策若有修訂，會隨 App 更新一併提供，並更新版本與生效日期。由於本 App 不收集聯絡資訊，若你對本政策有疑問，請透過你取得本 App 的管道與開發者聯繫。
                """)
,
        Section(heading: "九、備份與加密",
                body: """
                本 App 不含雲端同步，也沒有任何伺服器。你的資料只存在這支手機裡。

                【備份】你可以隨時在「設定 → 備份與還原」把所有紀錄、設定、校正值與課表匯出成一個檔案。這個檔案要存到哪裡（「檔案」App、iCloud 雲碟、電腦、傳給自己）完全由你決定，本 App 不會代你上傳到任何地方。

                【加密備份】匯出時可以選擇設定一組密碼。勾選之後，整份備份會先用 PBKDF2-HMAC-SHA256（21 萬輪迭代）從你的密碼衍生金鑰，再以 AES-256-GCM 加密後才寫入檔案，副檔名為 .gtbak。加密與解密全程都在你的裝置上完成，不需要連網。

                【你的責任】備份密碼由你自行保管。本 App 與開發者皆無從得知，也沒有任何後門可以還原。密碼遺失，該備份檔將永久無法開啟。

                【不加密的備份】若不勾選加密，備份檔是純文字 JSON，任何拿到檔案的人都能直接閱讀內容。要放到雲端硬碟或用通訊軟體傳送時，建議務必開啟加密。

                【刪除】解除安裝 App 會一併刪除裝置上的所有資料。已經匯出的備份檔不受影響，需要自行刪除。
                """)
    ]
    // MARK: - Privacy Policy (English)

    static let privacyEN: [Section] = [
        Section(heading: "1. Overview",
                body: """
                \(appNameEN) ("the App") is a workout tracker that runs entirely on your device. It has no backend server, requires no account, and never uploads your data to the developer or to any third party.

                The App contains no network sync of any kind. All data lives only on your phone; whether and where to back it up is entirely your decision (see section 9).

                This policy explains what the App accesses, why it needs it, where it is stored and how you stay in control. It takes effect on \(effectiveDateEN) and applies to version \(version).
                """),
        Section(heading: "2. What we do not collect",
                body: """
                The App never collects, transmits or sells any of the following:

                • Names, email addresses, phone numbers, dates of birth or any other personally identifying information
                • Advertising identifiers (IDFA), device identifiers or any tracking identifier
                • Usage analytics, crash reports or telemetry
                • Your workouts, location traces or health data

                The App bundles no third-party SDKs, advertising networks or analytics tools, and requires no outbound network connection.
                """),
        Section(heading: "3. Data the App accesses and why",
                body: """
                All of the following is processed locally, only after you grant permission:

                1. Location. Recorded only while you actively run a GPS mode, to compute your route, distance, pace and elevation. "Always" access exists so recording continues when the screen locks or the app moves to the background. Routes are stored on your device.

                2. Motion and fitness. Step count, cadence, flights climbed, accelerometer and gyroscope readings, barometric relative altitude and activity type (stationary, walking, running, cycling, automotive). Used for distance estimation in the no-GPS modes, repetition counting and walk/run segmentation.

                3. Health data (HealthKit). With your permission the App reads body mass, height, steps, walking + running distance, flights climbed, active energy, workouts and heart rate, and writes the workouts you complete here. Health data is used on device only and never leaves it.

                4. Data you enter yourself. Body weight, daily goals, weather notes, perceived exertion, notes, custom exercises and test standards.
                """),
        Section(heading: "4. Specific statement about Health data",
                body: """
                In line with Apple's requirements we state explicitly:

                • The App does not use any data obtained through HealthKit for advertising, marketing or similar purposes
                • The App does not disclose, sell or share HealthKit data with any third party
                • The App does not use HealthKit data for any purpose other than those described in this policy
                • You may revoke access at any time in iOS Settings → Privacy & Security → Health; the rest of the App keeps working
                """),
        Section(heading: "5. Storage and security",
                body: """
                Workouts, route points, settings and calibration data are stored with SwiftData inside the App's own sandbox on your device, protected by iOS file protection. The App does not use iCloud sync, so this data does not leave the device.

                Files you create with the export features (CSV, GPX, TCX, PDF) are handed to whichever destination you pick. Once you share a file with another app or service, that data is governed by their privacy policy.
                """),
        Section(heading: "6. Your control",
                body: """
                • Every permission can be declined; the related feature degrades or switches off and everything else keeps working
                • With location denied you can still use lap counting, intervals, bodyweight reps, fitness tests and manual entry in full
                • Settings → Data lets you export everything or delete all records in one step
                • Deleting the App removes all local data; workouts already written to Health must be deleted in the Health app
                """),
        Section(heading: "7. Children's privacy",
                body: """
                The App is not directed at children under 13 and does not knowingly collect personal information from children. It collects no personal information at all and has no account or social features.
                """),
        Section(heading: "8. Changes and contact",
                body: """
                Any revision ships with an App update and carries a new version and effective date. Because the App collects no contact information, please reach the developer through the channel you obtained the App from if you have questions.
                """)
,
        Section(heading: "9. Backup and encryption",
                body: """
                The App has no cloud sync and no server of any kind. Your data lives only on this phone.

                [Backup] You can export all records, settings, calibration values and workout plans to a single file at any time under Settings → Backup & Restore. Where that file goes (the Files app, iCloud Drive, a computer, a message to yourself) is entirely your decision; the App never uploads it anywhere on your behalf.

                [Encrypted backup] You may optionally set a password when exporting. If you do, the entire backup is encrypted with AES-256-GCM using a key derived from your password with PBKDF2-HMAC-SHA256 (210,000 iterations) before anything is written to disk; the file extension becomes .gtbak. Encryption and decryption happen entirely on your device and require no network connection.

                [Your responsibility] The backup password is yours alone. Neither the App nor the developer can learn it, and there is no backdoor to recover it. If the password is lost, that backup file can never be opened again.

                [Unencrypted backups] Without the password option, the backup file is plain-text JSON that anyone holding it can read. Always enable encryption before placing a backup on cloud storage or sending it through a messaging app.

                [Deletion] Deleting the App removes all of its data from the device. Backup files you have already exported are unaffected and must be deleted separately.
                """)
    ]

    // MARK: - 使用條款（中文）

    static let termsZH: [Section] = [
        Section(heading: "一、接受條款",
                body: """
                當你安裝或使用 \(appName)（以下稱「本 App」），即表示你已閱讀並同意本使用條款。若你不同意，請停止使用並移除本 App。本條款自 \(effectiveDate) 起生效，適用版本 \(version)。
                """),
        Section(heading: "二、授權範圍",
                body: """
                開發者授予你一項個人、非專屬、不可轉讓、可撤銷的授權，僅供你在自己擁有或控制的 Apple 裝置上，為個人非商業目的使用本 App。

                你不得：對本 App 進行還原工程、反編譯或拆解（法律明文允許者除外）；移除任何著作權或專有標示；將本 App 轉售、出租、出借或再授權。
                """),
        Section(heading: "三、非醫療用途聲明（重要）",
                body: """
                本 App 是一般健身與休閒用途的工具，不是醫療器材，也不提供醫療建議、診斷或治療。

                本 App 顯示的熱量、運動強度、心肺負荷、訓練負荷、步幅與距離估算，皆為以公式推算的參考值，並非量測結果，可能與實際狀況有明顯落差。

                開始任何運動計畫前，尤其若你有心血管疾病、呼吸系統疾病、骨骼肌肉傷害、懷孕或其他健康狀況，請先諮詢合格醫療專業人員。運動中若出現胸痛、暈眩、呼吸困難或任何不適，請立即停止並尋求協助。
                """),
        Section(heading: "四、資料準確性",
                body: """
                GPS 精度會受建築物、地形、天候與裝置狀態影響；計步器與氣壓計的讀值同樣存在誤差。無定位模式的距離是由步數與步幅推算，本質上是估算值。

                本 App 內的體能測驗評等標準為可自行編輯的參考值，預設值不代表任何機關、單位或組織的官方規定。你應以你所屬單位公告的最新標準為準。
                """),
        Section(heading: "五、風險自負",
                body: """
                你理解並同意，運動本身具有受傷風險。你自行決定運動的種類、強度與環境，並自行承擔全部風險。使用本 App 時請隨時注意周遭環境與交通安全，不要因查看螢幕而分心。
                """),
        Section(heading: "六、無保證",
                body: """
                本 App 以「現狀」及「現有」基礎提供，不附任何明示或默示的保證，包括但不限於適售性、特定目的適用性、準確性或不侵權之保證。開發者不保證本 App 不會中斷、無錯誤，或所有資料皆不會遺失。
                """),
        Section(heading: "七、責任限制",
                body: """
                在適用法律允許的最大範圍內，開發者對於因使用或無法使用本 App 而生的任何直接、間接、附隨、特別、懲罰性或衍生性損害（包括人身傷害、資料遺失、利潤損失）不負賠償責任。
                """),
        Section(heading: "八、側載安裝說明",
                body: """
                本 App 以未簽名 ipa 形式提供，需由你自行以合法方式簽名後安裝於自己的裝置。你應自行確認你的安裝方式符合你所在地的法律與 Apple 的相關條款，並自行承擔相關責任。開發者不提供憑證，亦不對簽名與安裝過程負責。
                """),
        Section(heading: "九、終止",
                body: """
                你可隨時刪除本 App 以終止本條款。終止後，本條款中關於免責、責任限制與準據法之條文仍繼續有效。
                """),
        Section(heading: "十、準據法",
                body: """
                本條款之解釋與適用，以及因本條款所生之爭議，均以中華民國（台灣）法律為準據法，並以台灣台北地方法院為第一審管轄法院，但不影響消費者依法享有的權利。
                """)
    ]

    // MARK: - Terms of Use (English)

    static let termsEN: [Section] = [
        Section(heading: "1. Acceptance",
                body: """
                By installing or using \(appNameEN) ("the App") you confirm that you have read and agree to these Terms. If you do not agree, stop using the App and remove it. These Terms take effect on \(effectiveDateEN) and apply to version \(version).
                """),
        Section(heading: "2. Licence",
                body: """
                You are granted a personal, non-exclusive, non-transferable, revocable licence to use the App for personal, non-commercial purposes on Apple devices you own or control.

                You may not reverse engineer, decompile or disassemble the App (except where the law expressly allows it), remove any copyright or proprietary notice, or resell, rent, lend or sublicense the App.
                """),
        Section(heading: "3. Not a medical device (important)",
                body: """
                The App is a general fitness and recreation tool. It is not a medical device and does not provide medical advice, diagnosis or treatment.

                Calories, exercise intensity, cardio load, training load, stride length and distance shown in the App are values derived from formulas, not measurements, and can differ noticeably from reality.

                Consult a qualified healthcare professional before starting any exercise programme, especially if you have a cardiovascular or respiratory condition, a musculoskeletal injury, are pregnant, or have any other health concern. Stop immediately and seek help if you experience chest pain, dizziness, breathing difficulty or any other distress.
                """),
        Section(heading: "4. Accuracy of data",
                body: """
                GPS accuracy is affected by buildings, terrain, weather and device condition; pedometer and barometer readings carry error too. Distance in the no-GPS modes is derived from step count and stride length and is by nature an estimate.

                The fitness test grading thresholds in the App are editable reference values. The defaults do not represent the official requirements of any authority, unit or organisation. Always follow the current standard published by your own organisation.
                """),
        Section(heading: "5. Assumption of risk",
                body: """
                You understand and accept that exercise carries a risk of injury. You choose the type, intensity and environment of your activity and assume all associated risk. Stay aware of your surroundings and of traffic; do not let the screen distract you.
                """),
        Section(heading: "6. No warranty",
                body: """
                The App is provided "as is" and "as available" without warranty of any kind, express or implied, including merchantability, fitness for a particular purpose, accuracy or non-infringement. The developer does not warrant that the App will be uninterrupted or error free, or that no data will ever be lost.
                """),
        Section(heading: "7. Limitation of liability",
                body: """
                To the maximum extent permitted by law, the developer is not liable for any direct, indirect, incidental, special, punitive or consequential damages (including personal injury, data loss or lost profits) arising from your use of, or inability to use, the App.
                """),
        Section(heading: "8. Sideloading",
                body: """
                The App is distributed as an unsigned ipa which you sign and install on your own device by lawful means. You are responsible for ensuring your installation method complies with the law where you are and with Apple's terms. The developer supplies no certificates and is not responsible for the signing or installation process.
                """),
        Section(heading: "9. Termination",
                body: """
                You may terminate these Terms at any time by deleting the App. The disclaimer, limitation of liability and governing law sections survive termination.
                """),
        Section(heading: "10. Governing law",
                body: """
                These Terms are governed by the laws of Taiwan (Republic of China), with the Taipei District Court as the court of first instance, without prejudice to any mandatory consumer rights you may have.
                """)
    ]
}
