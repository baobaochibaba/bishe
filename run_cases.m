clear; clc; close all;

%% ==================== 1. 场景设置 ====================
% 场景格式：[flag_DR, flag_ES]
scenes = [
    0 0;   % Case1: 基准场景
    0 1;   % Case2: 储能
    1 0;   % Case3: 需求响应
    1 1    % Case4: 需求响应 + 储能
];

short_case_names = {
    'Case1'
    'Case2'
    'Case3'
    'Case4'
};

flag_plot_each = 0;   % 批量运行时不画详细图

%% ==================== 2. 逐场景运行 ====================
results = struct([]);

for i = 1:size(scenes,1)
    flag_DR = scenes(i,1);
    flag_ES = scenes(i,2);

    fprintf('\n==============================\n');
    fprintf('正在运行 %s ...\n', short_case_names{i});
    fprintf('flag_DR = %d, flag_ES = %d\n', flag_DR, flag_ES);


    tmp = main_dispatch(flag_DR, flag_ES, short_case_names{i}, flag_plot_each);

    fprintf('返回变量类型：%s\n', class(tmp));

    if isempty(tmp)
        error('场景 %s 返回为空 []，请检查 main_dispatch 求解失败返回部分。', short_case_names{i});
    end

    if isfield(tmp, 'solve_success')
        if tmp.solve_success == 0
            error('场景 %s 求解失败，请检查 main_dispatch 输出信息。', short_case_names{i});
        end
    end

    disp('返回字段为：');
    disp(fieldnames(tmp));

    if i == 1
        results = tmp;   % 第一组先直接赋值
    else
        disp('当前 results 的字段为：');
        disp(fieldnames(results));

        if ~isequal(fieldnames(results), fieldnames(tmp))
            error('场景 %s 返回结构体字段与前面不一致。', short_case_names{i});
        end

        results(i) = tmp;
    end

    fprintf('\n------ %s 结果摘要 ------\n', short_case_names{i});
    fprintf('总成本 = %.4f 元\n', results(i).Obj);
    fprintf('不含碳成本 = %.4f 元\n', results(i).Obj_nocarbon);
    fprintf('购电成本 = %.4f 元\n', results(i).C_ele);
    fprintf('燃气成本 = %.4f 元\n', results(i).C_gas);
    fprintf('  其中CHP燃气成本 = %.4f 元\n', results(i).C_gas_chp);
    fprintf('  其中锅炉燃气成本 = %.4f 元\n', results(i).C_gas_gb);
    fprintf('需求响应成本 = %.4f 元\n', results(i).C_dr);
    fprintf('储能运行成本 = %.4f 元\n', results(i).C_es);
    fprintf('阶梯碳成本 = %.4f 元\n', results(i).C_carbon);
    fprintf('总碳排放 = %.4f kg\n', results(i).total_emission);

    if isfield(results(i), 'E_quota')
        fprintf('碳配额 = %.4f kg\n', results(i).E_quota);
    end

    if isfield(results(i), 'E_excess')
        fprintf('超额排放 = %.4f kg\n', results(i).E_excess);
    end

    if isfield(results(i), 'E_carbon_seg')
        fprintf('阶梯排放分配 = ');
        fprintf('%.2f ', results(i).E_carbon_seg);
        fprintf('kg\n');
    end

    fprintf('峰值购电 = %.4f kW\n', results(i).peak_grid);
    fprintf('谷值购电 = %.4f kW\n', results(i).valley_grid);
    fprintf('购电峰谷差 = %.4f kW\n', results(i).peak_valley_diff);

    if isfield(results(i), 'stage2_success')
        fprintf('第二阶段求解状态 stage2_success = %d\n', results(i).stage2_success);
    end
end

%% ==================== 3. 汇总表 ====================
nCase = length(results);

CaseName = strings(nCase,1);
DR = zeros(nCase,1);
ES = zeros(nCase,1);

Obj = zeros(nCase,1);
Obj_nocarbon = zeros(nCase,1);
C_ele = zeros(nCase,1);
C_gas = zeros(nCase,1);
C_gas_chp = zeros(nCase,1);
C_gas_gb = zeros(nCase,1);
C_dr = zeros(nCase,1);
C_es = zeros(nCase,1);
C_carbon = zeros(nCase,1);

Emission = zeros(nCase,1);
Emission_grid = zeros(nCase,1);
Emission_gas = zeros(nCase,1);

% 新增：配额与超额排放
E_quota = zeros(nCase,1);
E_excess = zeros(nCase,1);

PeakGrid = zeros(nCase,1);
ValleyGrid = zeros(nCase,1);
PeakValley = zeros(nCase,1);

% 两阶段相关指标
Stage1Best = zeros(nCase,1);
Stage1Final = zeros(nCase,1);
Stage2Obj = zeros(nCase,1);
Stage2Success = zeros(nCase,1);
CostIncreasePct = zeros(nCase,1);

% 第二阶段平滑/削峰指标
GridSmoothObj = zeros(nCase,1);
GBPeakObj = zeros(nCase,1);
GBSmoothObj = zeros(nCase,1);

% 设备统计量
Grid_buy = zeros(nCase,1);
PV_gen = zeros(nCase,1);
CHP_e = zeros(nCase,1);
CHP_h = zeros(nCase,1);
GB_h = zeros(nCase,1);
ES_ch = zeros(nCase,1);
ES_dis = zeros(nCase,1);
HS_ch = zeros(nCase,1);
HS_dis = zeros(nCase,1);

% DR统计量
E_shift_abs = zeros(nCase,1);
E_cut = zeros(nCase,1);
H_shift_abs = zeros(nCase,1);
H_cut = zeros(nCase,1);

% 阶梯碳段数量
if isfield(results(1), 'E_carbon_seg')
    N_seg = length(results(1).E_carbon_seg);
else
    N_seg = 0;
end

E_carbon_seg_mat = zeros(nCase, N_seg);
C_carbon_seg_mat = zeros(nCase, N_seg);

if isfield(results(1), 'carbon_seg_price')
    carbon_seg_price = results(1).carbon_seg_price(:);
else
    carbon_seg_price = [];
end

if isfield(results(1), 'carbon_seg_width')
    carbon_seg_width = results(1).carbon_seg_width(:);
else
    carbon_seg_width = [];
end

for i = 1:nCase
    CaseName(i) = results(i).case_name;
    DR(i) = results(i).flag_DR;
    ES(i) = results(i).flag_ES;

    Obj(i) = results(i).Obj;
    Obj_nocarbon(i) = results(i).Obj_nocarbon;
    C_ele(i) = results(i).C_ele;
    C_gas(i) = results(i).C_gas;
    C_gas_chp(i) = results(i).C_gas_chp;
    C_gas_gb(i) = results(i).C_gas_gb;
    C_dr(i) = results(i).C_dr;
    C_es(i) = results(i).C_es;
    C_carbon(i) = results(i).C_carbon;

    Emission(i) = results(i).total_emission;
    Emission_grid(i) = results(i).E_CO2_grid;
    Emission_gas(i) = results(i).E_CO2_gas;

    if isfield(results(i), 'E_quota')
        E_quota(i) = results(i).E_quota;
    else
        E_quota(i) = NaN;
    end

    if isfield(results(i), 'E_excess')
        E_excess(i) = results(i).E_excess;
    else
        E_excess(i) = NaN;
    end

    PeakGrid(i) = results(i).peak_grid;
    ValleyGrid(i) = results(i).valley_grid;
    PeakValley(i) = results(i).peak_valley_diff;

    if isfield(results(i), 'Obj_stage1_best')
        Stage1Best(i) = results(i).Obj_stage1_best;
    else
        Stage1Best(i) = NaN;
    end

    if isfield(results(i), 'Obj_stage1_final')
        Stage1Final(i) = results(i).Obj_stage1_final;
    else
        Stage1Final(i) = NaN;
    end

    if isfield(results(i), 'Obj_stage2')
        Stage2Obj(i) = results(i).Obj_stage2;
    else
        Stage2Obj(i) = NaN;
    end

    if isfield(results(i), 'stage2_success')
        Stage2Success(i) = results(i).stage2_success;
    else
        Stage2Success(i) = NaN;
    end

    if ~isnan(Stage1Best(i)) && Stage1Best(i) ~= 0
        CostIncreasePct(i) = 100 * (Obj(i) - Stage1Best(i)) / Stage1Best(i);
    else
        CostIncreasePct(i) = NaN;
    end

    if isfield(results(i), 'grid_smooth_obj')
        GridSmoothObj(i) = results(i).grid_smooth_obj;
    else
        GridSmoothObj(i) = NaN;
    end

    if isfield(results(i), 'gb_peak_obj')
        GBPeakObj(i) = results(i).gb_peak_obj;
    else
        GBPeakObj(i) = NaN;
    end

    if isfield(results(i), 'gb_smooth_obj')
        GBSmoothObj(i) = results(i).gb_smooth_obj;
    else
        GBSmoothObj(i) = NaN;
    end

    Grid_buy(i) = sum(results(i).P_grid);
    PV_gen(i) = sum(results(i).P_PV);
    CHP_e(i) = sum(results(i).P_CHP_e);
    CHP_h(i) = sum(results(i).P_CHP_h);
    GB_h(i) = sum(results(i).P_GB_h);
    ES_ch(i) = sum(results(i).P_ES_ch);
    ES_dis(i) = sum(results(i).P_ES_dis);
    HS_ch(i) = sum(results(i).P_HS_ch);
    HS_dis(i) = sum(results(i).P_HS_dis);

    E_shift_abs(i) = sum(abs(results(i).P_e_shift));
    E_cut(i) = -sum(results(i).P_e_cut);
    H_shift_abs(i) = sum(abs(results(i).P_h_shift));
    H_cut(i) = -sum(results(i).P_h_cut);

    if N_seg > 0
        E_carbon_seg_mat(i,:) = results(i).E_carbon_seg(:)';

        if ~isempty(carbon_seg_price)
            C_carbon_seg_mat(i,:) = results(i).E_carbon_seg(:)' .* carbon_seg_price(:)';
        end
    end
end

ResultTable = table( ...
    CaseName, DR, ES, ...
    Obj, Obj_nocarbon, C_ele, C_gas, C_gas_chp, C_gas_gb, C_dr, C_es, C_carbon, ...
    Emission, Emission_grid, Emission_gas, E_quota, E_excess, ...
    PeakGrid, ValleyGrid, PeakValley, ...
    Stage1Best, Stage1Final, Stage2Obj, Stage2Success, CostIncreasePct, ...
    GridSmoothObj, GBPeakObj, GBSmoothObj, ...
    Grid_buy, PV_gen, CHP_e, CHP_h, GB_h, ES_ch, ES_dis, HS_ch, HS_dis, ...
    E_shift_abs, E_cut, H_shift_abs, H_cut);

disp(' ');
disp('========== 场景汇总结果 ==========');
disp(ResultTable);

%% ==================== 3.1 阶梯碳价分段汇总表 ====================
if N_seg > 0
    SegNames_E = strings(1, N_seg);
    SegNames_C = strings(1, N_seg);

    for s = 1:N_seg
        SegNames_E(s) = "E_seg" + string(s);
        SegNames_C(s) = "C_seg" + string(s);
    end

    CarbonSegEmissionTable = array2table(E_carbon_seg_mat, 'VariableNames', cellstr(SegNames_E));
    CarbonSegCostTable = array2table(C_carbon_seg_mat, 'VariableNames', cellstr(SegNames_C));

    CarbonStepTable = [table(CaseName), CarbonSegEmissionTable, CarbonSegCostTable];

    disp(' ');
    disp('========== 阶梯碳价分段结果 ==========');
    disp(CarbonStepTable);
else
    CarbonStepTable = table();
end

save('results_cases_two_stage_stepcarbon.mat', ...
    'results', 'ResultTable', 'CarbonStepTable', ...
    'E_carbon_seg_mat', 'C_carbon_seg_mat', ...
    'carbon_seg_price', 'carbon_seg_width');

%% ==================== 4. 跨场景对比图 ====================
myColors = { '#80D0E4', '#AAD498','#DD9F95','#568BC1','#BC9DA8','#A6C9C1'};
% 4.1 总成本对比
figure('Name','场景总成本对比');
hold on;

% 逐个绘制柱子，每个柱子用对应的十六进制颜色
for i = 1:4
    bar(i, Obj(i),0.6, 'FaceColor', myColors{i}, 'EdgeColor', 'none');
end

hold off;
set(gca, 'XTick', 1:4, 'XTickLabel', short_case_names, ...
         'FontSize', 12);
ylabel('元');
grid on;
% 4.2 成本构成对比
figure('Name','成本构成对比');
b = bar([C_ele, C_gas_chp, C_gas_gb, C_dr, C_es, C_carbon],0.6, 'stacked');
for i = 1:6
    set(b(i), 'FaceColor', myColors{i}, 'EdgeColor', 'none');
end
legend('购电','CHP','锅炉','IDR','储能','阶梯碳', ...
    'Location','best', 'FontSize', 14);
set(gca,'XTickLabel',short_case_names, 'FontSize', 12); 
ylabel('元');
grid on;

% 4.3 含碳/不含碳总成本对比
figure('Name','含碳与不含碳总成本对比');
b = bar([Obj_nocarbon, C_carbon],0.6, 'stacked');
set(b(1), 'FaceColor', myColors{1}, 'EdgeColor', 'none'); 
set(b(2), 'FaceColor', myColors{2}, 'EdgeColor', 'none'); 
legend('不含碳运行成本','阶梯碳成本','Location','best', 'FontSize', 12);
set(gca,'XTickLabel',short_case_names, 'FontSize', 12); 
ylabel('元');
grid on;

figure('Name', '总碳排放对比');
hold on;

for i = 1:4
    if i == 1
        % 第一个柱子正常画，并设置图例显示名
        bar(i, Emission(i),0.6, 'FaceColor', myColors{i}, 'EdgeColor', 'none', ...
            'HandleVisibility', 'off');
    else
        % 其他柱子不显示在图例中
        bar(i, Emission(i),0.6, 'FaceColor', myColors{i}, 'EdgeColor', 'none', ...
            'HandleVisibility', 'off');
    end
end

% 碳配额线
if all(~isnan(E_quota))
    xlims = xlim;
    quotaValue = E_quota(1);
    plot(xlims, [quotaValue, quotaValue], 'k--', 'LineWidth', 0.8, ...
        'DisplayName', '碳配额');
end

hold off;
set(gca, 'XTick', 1:4, 'XTickLabel', short_case_names, ...
          'FontSize', 12);
ylabel('kg');
legend('Location', 'best');
grid on;

% 4.5 碳排放来源对比
figure('Name','碳排放来源对比');


b = bar([Emission_grid, Emission_gas],0.6, 'stacked');
set(b(1),'FaceColor', myColors{1}, 'EdgeColor', 'none');  % 电网购电排放
set(b(2),'FaceColor', myColors{2}, 'EdgeColor', 'none');  % 燃气排放

hold on;

if all(~isnan(E_quota))
    xlims = xlim;                             
    quotaValue = E_quota(1);                  
    plot(xlims, [quotaValue, quotaValue], 'k--', 'LineWidth', 0.8);  
    legend('电网购电排放','燃气排放','碳配额','Location','best', 'FontSize', 14);
else
    legend('电网购电排放','燃气排放','Location','best', 'FontSize', 14);
end

set(gca,'XTickLabel',short_case_names, 'FontSize', 12);
ylabel('kgCO2');
grid on;

% 4.6 超额排放对比
figure('Name','超额排放对比');
hold on;

myWidth = 0.6;   

for i = 1:4
    bar(i, E_excess(i), myWidth, ...
        'FaceColor', myColors{i}, ...
        'EdgeColor', 'none');
end

hold off;
set(gca, 'XTick', 1:4, ...
         'XTickLabel', short_case_names, ...
         'FontSize', 12);
ylabel('kgCO2');
grid on;

% 4.7 阶梯碳成本对比
figure('Name', '阶梯碳成本对比');
hold on;

myWidth = 0.6;   % 与前面图形保持一致的柱子粗细

for i = 1:4
    bar(i, C_carbon(i), myWidth, ...
        'FaceColor', myColors{i}, ...
        'EdgeColor', 'none');
end

hold off;
set(gca, 'XTick', 1:4, ...
         'XTickLabel', short_case_names, ...
         'FontSize', 12);
ylabel('元');
grid on;

% 4.8 阶梯超额排放分配堆叠图
if N_seg > 0
    figure('Name','阶梯超额排放分配');
    

    b = bar(E_carbon_seg_mat,0.6, 'stacked');
    for s = 1:N_seg
        colorIdx = mod(s-1, numel(myColors)) + 1;
        set(b(s), 'FaceColor', myColors{colorIdx}, 'EdgeColor', 'none');
    end
    set(gca,'XTickLabel',short_case_names, 'FontSize', 12);
    legend_labels = cell(N_seg,1);
    for s = 1:N_seg
        if ~isempty(carbon_seg_price)
            legend_labels{s} = sprintf('%d ', s);
        else
            legend_labels{s} = sprintf('%d', s);
        end
    end
    legend(legend_labels, 'Location','best', 'FontSize', 12);
    ylabel('kgCO2');
    grid on;
end

% 4.9 阶梯碳成本分段贡献堆叠图
if N_seg > 0
    figure('Name','阶梯碳成本分段贡献');
    b = bar(C_carbon_seg_mat,0.6, 'stacked');
    for s = 1:N_seg
        colorIdx = mod(s-1, numel(myColors)) + 1;  % 颜色不够时循环取用
        set(b(s), 'FaceColor', myColors{colorIdx}, 'EdgeColor', 'none');
    end
    set(gca,'XTickLabel',short_case_names, 'FontSize', 12);
    legend_labels = cell(N_seg,1);
    for s = 1:N_seg
        if ~isempty(carbon_seg_price)
            legend_labels{s} = sprintf('第%d段', s);
        else
            legend_labels{s} = sprintf('第%d段', s);
        end
    end
    legend(legend_labels, 'Location','best', 'FontSize', 14);
    ylabel('元');
    grid on;
end

% 4.10 峰值购电对比
figure('Name','购电峰谷差对比');
hold on;

myWidth = 0.6;

for i = 1:4
    bar(i, PeakValley(i), myWidth, ...
        'FaceColor', myColors{i}, ...
        'EdgeColor', 'none');
end

hold off;
set(gca, 'XTick', 1:4, ...
         'XTickLabel', short_case_names, ...
         'FontSize', 12);
ylabel('kW');
grid on;


% 4.12 第二阶段购电波动指标对比
figure('Name','购电波动指标对比');
hold on;

myWidth = 0.6;

for i = 1:4
    bar(i, GridSmoothObj(i), myWidth, ...
        'FaceColor', myColors{i}, ...
        'EdgeColor', 'none');
end

hold off;
set(gca, 'XTick', 1:4, ...
         'XTickLabel', short_case_names, ...
         'FontSize', 12);
ylabel('kW');
grid on;

% 4.13 购电曲线对比
figure('Name','购电曲线对比');
hold on;
for i = 1:nCase
    plot(1:24, results(i).P_grid, '-o', 'LineWidth', 1.5);
end
legend(short_case_names, 'Location', 'best', 'FontSize', 12);
xlabel('时段');
ylabel('kW');
grid on;

% 4.14 电源结构对比
figure('Name','电源结构对比');
b = bar([PV_gen, CHP_e, ES_dis, Grid_buy],0.6, 'stacked');
for s = 1:4  % 四层：光伏、CHP、电储能、电网购电
    colorIdx = mod(s-1, numel(myColors)) + 1;
    set(b(s), 'FaceColor', myColors{colorIdx}, 'EdgeColor', 'none');
end
set(gca,'XTickLabel',short_case_names, 'FontSize', 12);
legend('光伏发电','CHP发电','电储能放电','电网购电','Location','best', 'FontSize', 12);
ylabel('kWh');
grid on;
% 4.15 热源结构对比
figure('Name','热源结构对比');
b = bar([CHP_h, GB_h, HS_dis],0.6, 'stacked');
for s = 1:3 
    colorIdx = mod(s-1, numel(myColors)) + 1;
    set(b(s), 'FaceColor', myColors{colorIdx}, 'EdgeColor', 'none');
end

set(gca,'XTickLabel',short_case_names, 'FontSize', 12);
legend('CHP供热','锅炉供热','热储能放热','Location','best', 'FontSize', 12);
ylabel('kWh');
grid on;

% 4.16 储能充放电对比
figure('Name','储能充放电总量对比');
subplot(1,2,1);
bar([ES_ch, ES_dis]);
set(gca,'XTickLabel',short_case_names, 'FontSize', 12);
legend('电储能充电','电储能放电','Location','best', 'FontSize', 12);
ylabel('kWh');
grid on;

subplot(1,2,2);
bar([HS_ch, HS_dis]);
set(gca,'XTickLabel',short_case_names, 'FontSize', 12);
legend('热储能蓄热','热储能放热','Location','best', 'FontSize', 12);
ylabel('kWh');
grid on;

% 4.17 需求响应量对比
figure('Name','需求响应总量对比');
subplot(1,2,1);
bar([E_shift_abs, E_cut]);
set(gca,'XTickLabel',short_case_names, 'FontSize', 12);
legend('电负荷转移总量','电负荷削减总量','Location','best', 'FontSize', 12);
ylabel('kWh');
grid on;

subplot(1,2,2);
bar([H_shift_abs, H_cut]);
set(gca,'XTickLabel',short_case_names, 'FontSize', 12);
legend('热负荷转移总量','热负荷削减总量','Location','best', 'FontSize', 12);
ylabel('kWh');
grid on;

%% ==================== 5. 各场景典型运行曲线细节图 ====================

% 5.1 每个场景购电曲线单独子图
figure('Name','各场景购电曲线细节');
for i = 1:nCase
    subplot(nCase,1,i);
    plot(1:24, results(i).P_grid, 'b-o', 'LineWidth', 1.5);
    ylabel('kW');
    title(short_case_names{i});
    grid on;
end
xlabel('时段');

% 5.2 每个场景锅炉供热曲线
figure('Name','各场景锅炉供热曲线细节');
for i = 1:nCase
    subplot(nCase,1,i);
    plot(1:24, results(i).P_GB_h, 'r-o', 'LineWidth', 1.5);
    ylabel('kW');
    title(short_case_names{i});
    grid on;
end
xlabel('时段');

% 5.3 每个场景SOC曲线
figure('Name','储能SOC对比');
for i = 1:nCase
    subplot(nCase,2,2*i-1);
    plot(1:24, results(i).SOC_e, 'b-o', 'LineWidth', 1.4);
    ylabel('kWh');
    title([short_case_names{i}, ' - 电储能SOC']);
    grid on;

    subplot(nCase,2,2*i);
    plot(1:24, results(i).SOC_h, 'r-o', 'LineWidth', 1.4);
    ylabel('kWh');
    title([short_case_names{i}, ' - 热储能SOC']);
    grid on;
end

figure('Name','储能SOC对比');

i = 4;  % 只画 case4

subplot(1,2,1);
plot(1:24, results(i).SOC_e, 'b-o', 'LineWidth', 1.4);
ylabel('kWh');
title([short_case_names{i}, ' - 电储能SOC']);
grid on;

subplot(1,2,2);
plot(1:24, results(i).SOC_h, 'r-o', 'LineWidth', 1.4);
ylabel('kWh');
title([short_case_names{i}, ' - 热储能SOC']);
grid on;

% 5.4 每个场景碳排放来源
figure('Name','各场景碳排放来源细节');
b = bar([Emission_grid, Emission_gas],0.6, 'stacked');
set(b(1), 'FaceColor', myColors{1}, 'EdgeColor', 'none');  % 电网购电排放
set(b(2), 'FaceColor', myColors{2}, 'EdgeColor', 'none');  % 燃气排放
hold on;
if all(~isnan(E_quota))
    xlims = xlim;
    quotaValue = E_quota(1);
    plot(xlims, [quotaValue, quotaValue], 'k--', 'LineWidth', 0.8);
    legend('电网购电排放','燃气排放','碳配额','Location','best', 'FontSize', 12);
else
    legend('电网购电排放','燃气排放','Location','best', 'FontSize', 12);
end
set(gca,'XTickLabel',short_case_names, 'FontSize', 12);
ylabel('kgCO2');
grid on;

%% ==================== 6. 单独画最终场景详细图 ====================
main_dispatch(1, 1, 'Case4-DR+ES', 1);