using System.Text;
using System.Text.Json;

namespace DshNotchWin;

/// <summary>
/// Synthetic long-detail markdown / snapshot for <c>--selftest</c> and
/// <c>--shot --ask-long</c>. The previous fixed string filled a 2560×1392
/// 100% DPI panel exactly (scroll 1027/1027), so ParseScrollProbe saw
/// overflow 0. Size from the live work area so the detail is a real
/// scroll region at 100% 1440p and 4K.
/// </summary>
internal static class LongDetailSelftestFixture
{
    internal static string BuildMarkdown(int workAreaHeight)
    {
        int workH = Math.Max(workAreaHeight, 720);
        // ~22 CSS px per wrapped line, ~32 CJK chars per 480 CSS-px panel.
        // Target ~1.6× the work area so the detail viewport (panel minus nav)
        // cannot swallow the fixture on 100% 1440p or 4K.
        int targetPx = workH + Math.Max(480, workH / 2);
        int minChars = Math.Max(NotchWindow.LongDetailThreshold + 1, (targetPx / 22) * 32);

        var detail = new StringBuilder();
        detail.Append("# 迁移计划\n\n");
        detail.Append("第一阶段把宿主插件层接到 Windows 的 WebView2 外壳上，第二阶段接通真实数据与几何动画，第三阶段做 AskUserQuestion 向导，第四阶段做 StatusOrbit 的四态笔画，第五阶段做待机机器人，第六阶段做安装、自启与卸载。每一阶段都要留下可复现的证据：自检项、截图与实测数字，而不是一句已经完成。第六阶段的卸载还要能一键回滚到未安装状态，且不在系统里留下任何残留文件与注册表项。安装脚本必须能在没有管理员权限的情况下完成接入，卸载脚本要恢复用户原有的 profile 配置备份，并保证重复执行是幂等的。\n\n");
        detail.Append("宿主插件层与原生界面层之间只有一份契约：宿主在 webServer 上挂载前缀路由，并把运行时文件写给 helper，里面只有来源地址与一次性令牌。界面层不持有任何密钥，也不直接访问网络，所有副作用都由宿主进程代为执行。这样做的代价是每条交互都要多一次进程间往返，收益是令牌永远不会进入页面脚本，页面即使被注入也无法伪造宿主身份。\n\n");
        detail.Append("几何动画由宿主的专用线程驱动，而不是由页面的 CSS 动画近似：显示器的刷新率是 240 赫兹，而系统定时器被固定在约 64 赫兹，用页面动画会在高刷新率屏幕上出现明显的台阶。逐帧直接调用窗口管理器接口，实测可以达到 220 到 450 赫兹，并且每一帧都能断言外侧边缘与顶部位置不变。\n\n");
        detail.Append("窗口的透明与命中测试由窗口区域同时负责。早先用颜色键做透明时，外观完全正常，但整个窗口对鼠标透明，点击全部穿透到背后的应用，只有在关闭穿透的前提下用命中测试断言才能发现。因此视觉检查与命中测试必须分别断言，几何断言全绿并不等于画面正确。\n\n");
        detail.Append("回答题目时宿主临时借用键盘焦点，用完立刻归还；面板在题目待回答期间不会自动折叠，否则用户刚把鼠标移开就会丢掉正在输入的内容。长文本的题目不再贴合内容高度，而是占满屏幕并把详情变成可滚动区域，保证选项按钮始终留在屏幕上。\n\n");

        const string pad =
            "每一阶段都要留下可复现的证据：自检项、截图与实测数字，而不是一句已经完成。"
            + "卸载要能一键回滚到未安装状态，且不在系统里留下任何残留文件与注册表项。"
            + "安装脚本必须能在没有管理员权限的情况下完成接入，并保证重复执行是幂等的。\n\n";
        while (detail.Length < minChars)
            detail.Append(pad);
        return detail.ToString();
    }

    internal static string BuildSnapshotJson(int workAreaHeight)
    {
        var snapshot = new NotchSnapshot
        {
            Ok = true,
            GeneratedAt = 910005,
            Origin = "http://127.0.0.1:1",
        };
        snapshot.Rows.Add(new NotchRow
        {
            Id = "probe-ask",
            Title = "probe asking session",
            Ask = new NotchAsk
            {
                Id = "ask-probe-3",
                Questions =
                {
                    new NotchQuestion
                    {
                        Id = "q1",
                        Question = "这份计划可以吗？",
                        Detail = BuildMarkdown(workAreaHeight),
                        Options = new List<NotchOption>
                        {
                            new() { Label = "可以" },
                            new() { Label = "要改" },
                        },
                    },
                },
            },
        });
        return JsonSerializer.Serialize(snapshot, NotchJson.Options);
    }
}
