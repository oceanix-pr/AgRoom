import Foundation

extension NativeAppTemplates {
    public static func quoteEstimate() throws -> NativeAppDefinition { try estimateTask(quote: true) }
    public static func workHours() throws -> NativeAppDefinition { try estimateTask(quote: false) }

    private static func estimateTask(quote: Bool) throws -> NativeAppDefinition {
        typealias App = NativeAppDefinition
        var labels: [String:[String:String]] = [:]
        for (language, quoteName, timeName, quoteSummary, timeSummary, input, sample, calculate, result, quoteExpected, timeExpected, resultHelp) in [
            ("en", "Quote Estimate", "Work Hours", "Estimate quantity × unit price × tax multiplier locally.", "Add task durations and multiply by repetitions locally.", "Expression", "Fill sample", "Calculate", "Last result", "Sample: 3 × 120 × 1.10 = 396. Check quantity, price, currency and tax assumptions before use.", "Sample: (1.5 + 2.25 + 0.75) × 3 = 13.5 hours. Use hours consistently and check for duplicated work.", "After editing the expression, calculate again. A sample pass does not validate your own assumptions."),
            ("zh-Hans", "报价试算", "工时合计", "在本机计算数量 × 单价 × 含税系数。", "在本机合计各项工时，再乘重复次数。", "算式", "填入样例", "计算", "上次计算结果", "样例：3 × 120 × 1.10 = 396。使用前核对数量、单价、币种及税率假设。", "样例：(1.5 + 2.25 + 0.75) × 3 = 13.5 小时。请统一用小时，并检查是否重复计入。", "修改算式后请重新计算。样例通过不代表你自己的业务假设已验证。"),
            ("zh-Hant", "報價試算", "工時合計", "在本機計算數量 × 單價 × 含稅係數。", "在本機合計各項工時，再乘重複次數。", "算式", "填入範例", "計算", "上次計算結果", "範例：3 × 120 × 1.10 = 396。使用前核對數量、單價、幣別及稅率假設。", "範例：(1.5 + 2.25 + 0.75) × 3 = 13.5 小時。請統一用小時，並檢查是否重複計入。", "修改算式後請重新計算。範例通過不代表你自己的業務假設已驗證。"),
            ("es", "Estimación de presupuesto", "Horas de trabajo", "Calcula localmente cantidad × precio unitario × factor de impuestos.", "Suma las duraciones y multiplícalas por el número de repeticiones.", "Expresión", "Rellenar ejemplo", "Calcular", "Último resultado", "Ejemplo: 3 × 120 × 1.10 = 396. Revisa la cantidad, el precio, la moneda y los impuestos.", "Ejemplo: (1.5 + 2.25 + 0.75) × 3 = 13.5 horas. Usa la misma unidad y revisa las duplicaciones.", "Vuelve a calcular después de editar la expresión. Revisa los supuestos de tus propios datos."),
            ("fr", "Estimation de devis", "Heures de travail", "Calculez localement quantité × prix unitaire × coefficient de taxe.", "Additionnez les durées et multipliez-les par le nombre de répétitions.", "Expression", "Remplir l’exemple", "Calculer", "Dernier résultat", "Exemple: 3 × 120 × 1.10 = 396. Vérifiez la quantité, le prix, la devise et les taxes.", "Exemple: (1.5 + 2.25 + 0.75) × 3 = 13.5 heures. Utilisez la même unité et vérifiez les doublons.", "Après modification de l’expression, relancez le calcul. Vérifiez les hypothèses de vos propres données."),
            ("ar", "تقدير عرض السعر", "ساعات العمل", "احسب محليًا الكمية × سعر الوحدة × معامل الضريبة.", "اجمع المدد واضربها في عدد التكرارات.", "العملية الحسابية", "إدراج المثال", "احسب", "آخر نتيجة", "مثال: 3 × 120 × 1.10 = 396. راجع الكمية والسعر والعملة والضريبة.", "مثال: (1.5 + 2.25 + 0.75) × 3 = 13.5 ساعة. وحّد الوحدات وراجع التكرارات.", "أعد الحساب بعد تعديل العملية. راجع الافتراضات الخاصة ببياناتك."),
            ("ru", "Расчёт стоимости", "Учёт рабочего времени", "Локальный расчёт количества × цены за единицу × коэффициента налога.", "Сложите длительности и умножьте на число повторений.", "Выражение", "Подставить пример", "Рассчитать", "Последний результат", "Пример: 3 × 120 × 1.10 = 396. Проверьте количество, цену, валюту и налоги.", "Пример: (1.5 + 2.25 + 0.75) × 3 = 13.5 часа. Используйте одну единицу времени и проверьте повторы.", "После изменения выражения повторите расчёт. Проверьте допущения для собственных данных.")
        ] {
            labels[language] = ["name":quote ? quoteName : timeName, "summary":quote ? quoteSummary : timeSummary,
                "input":input, "sample":sample, "calculate":calculate, "result":result,
                "expected":quote ? quoteExpected : timeExpected, "result-help":resultHelp]
        }
        let definition = App(manifest: .init(id: quote ? "quote-estimate" : "work-hours", version: 1, dslVersion: 1,
            nameKey: "name", summaryKey: "summary", icon: quote ? "tag" : "clock", width: 680, height: 540),
            i18n: labels, state: ["expression":.init(initial: .string(""), persistent: true), "result":.init(initial: .string(""), persistent: true)], dataSources: [:],
            views: .init(id: "root", type: .vstack, children: [
                .init(id: "title", type: .text, textKey: "name", style: .title),
                .init(id: "summary", type: .text, textKey: "summary"),
                .init(id: "expected", type: .text, textKey: "expected", style: .secondary),
                .init(id: "input", type: .textField, textKey: "input", stateKey: "expression"),
                .init(id: "buttons", type: .hstack, children: [
                    .init(id: "sample", type: .button, textKey: "sample", action: "sample"),
                    .init(id: "calculate", type: .button, textKey: "calculate", action: "calculate")]),
                .init(id: "result-label", type: .text, textKey: "result"),
                .init(id: "result", type: .text, binding: .init(state: "result"), style: .title),
                .init(id: "result-help", type: .text, textKey: "result-help", style: .secondary)
            ]), actions: [
                "sample":.init(type: .setState, stateKey: "expression", value: .init(literal: .string(quote ? "3 × 120 × 1.10" : "(1.5 + 2.25 + 0.75) × 3"))),
                "calculate":.init(type: .transformState, stateKey: "result", value: .init(state: "expression"), operation: .calculate)
            ])
        try definition.validate(); return definition
    }

    /// A complete keypad uses only local state operations, including in preview.
    public static func calculator() throws -> NativeAppDefinition {
        typealias App = NativeAppDefinition
        var labels: [String: [String: String]] = [:]
        for (language, name, summary, expression, result, clear, backspace, answer) in [
            ("en", "Calculator", "A local decimal calculator with a full keypad.", "Expression", "Result", "Clear", "Delete", "Use result"),
            ("zh-Hans", "按键计算器", "全按键式小数计算器，支持连续计算。", "算式", "结果", "清空", "退格", "使用结果"),
            ("zh-Hant", "按鍵計算器", "全按鍵式小數計算器，支援連續計算。", "算式", "結果", "清空", "退格", "使用結果"),
            ("es", "Calculadora", "Calculadora decimal local con teclado completo.", "Expresión", "Resultado", "Limpiar", "Borrar", "Usar resultado"),
            ("fr", "Calculatrice", "Calculatrice décimale locale avec clavier complet.", "Expression", "Résultat", "Effacer", "Supprimer", "Utiliser le résultat"),
            ("ar", "الآلة الحاسبة", "آلة حاسبة محلية للأعداد العشرية بلوحة مفاتيح كاملة.", "العملية الحسابية", "النتيجة", "مسح", "حذف", "استخدام النتيجة"),
            ("ru", "Калькулятор", "Локальный десятичный калькулятор с полной клавиатурой.", "Выражение", "Результат", "Очистить", "Удалить", "Использовать результат")
        ] {
            labels[language] = ["name": name, "summary": summary, "expression": expression, "result": result,
                                "clear": clear, "backspace": backspace, "answer": answer, "equals": "="]
        }
        var actions: [String: App.Action] = [
            "clear": .init(type: .setState, stateKey: "expression", value: .init(literal: .string(""))),
            "backspace": .init(type: .transformState, stateKey: "expression", operation: .removeLast),
            "equals": .init(type: .transformState, stateKey: "result", value: .init(state: "expression"), operation: .calculate),
            "answer": .init(type: .setState, stateKey: "expression", value: .init(state: "result"))
        ]
        let keys = (0...9).map { ("digit-\($0)", String($0)) }
            + [("decimal", "."), ("add", "+"), ("subtract", "−"), ("multiply", "×"), ("divide", "÷"), ("open", "("), ("close", ")")]
        for (key, value) in keys {
            for language in Array(labels.keys) { labels[language]?[key] = value }
            actions[key] = .init(type: .transformState, stateKey: "expression", value: .init(literal: .string(value)), operation: .append)
        }
        let rows = [["clear", "backspace", "open", "close"], ["digit-7", "digit-8", "digit-9", "divide"],
                    ["digit-4", "digit-5", "digit-6", "multiply"], ["digit-1", "digit-2", "digit-3", "subtract"],
                    ["digit-0", "decimal", "equals", "add"], ["answer"]]
        let buttons = rows.enumerated().map { index, keys in
            App.Node(id: "row-\(index)", type: .hstack, children: keys.map { key in
                App.Node(id: "button-" + key, type: .button, textKey: key, action: key)
            })
        }
        let definition = App(manifest: .init(id: "button-calculator", version: 1, dslVersion: 1,
            nameKey: "name", summaryKey: "summary", icon: "plus.forwardslash.minus", width: 520, height: 640),
            i18n: labels, state: ["expression": .init(initial: .string(""), persistent: true),
                                  "result": .init(initial: .string("0"), persistent: true)], dataSources: [:],
            views: .init(id: "root", type: .vstack, children: [
                .init(id: "expression-field", type: .textField, textKey: "expression", stateKey: "expression"),
                .init(id: "result-label", type: .text, textKey: "result", style: .secondary),
                .init(id: "result-value", type: .text, binding: .init(state: "result"), style: .title)
            ] + buttons), actions: actions)
        try definition.validate()
        return definition
    }
}
