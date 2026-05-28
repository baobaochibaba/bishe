function result = main_dispatch(flag_DR, flag_ES, case_name, flag_plot)

yalmip('clear');

%% ==================== 0. 默认参数处理 ====================
if nargin < 1 || isempty(flag_DR)
    flag_DR = 1;
end
if nargin < 2 || isempty(flag_ES)
    flag_ES = 1;
end
if nargin < 3 || isempty(case_name)
    case_name = 'TwoStageCase';
end
if nargin < 4 || isempty(flag_plot)
    flag_plot = 1;
end

%% ==================== 1. 读取输入数据 ====================
load('dispatch_input.mat');  
% 应包含：load_e, load_h, Q_24h, price_e, pv_avail

T = 24;
t = 1:T;

load_e = load_e(:);
load_h = load_h(:);
Q_24h = Q_24h(:);
price_e = price_e(:);

if exist('pv_avail','var')
    pv_avail = pv_avail(:);
else
    error('dispatch_input.mat 中缺少 pv_avail，请补充24小时光伏可用出力数据。');
end

if length(load_e) ~= T, error('load_e 长度不是24'); end
if length(load_h) ~= T, error('load_h 长度不是24'); end
if length(Q_24h) ~= T, error('Q_24h 长度不是24'); end
if length(price_e) ~= T, error('price_e 长度不是24'); end
if length(pv_avail) ~= T, error('pv_avail 长度不是24'); end

if any(isnan(load_e)) || any(isnan(load_h)) || any(isnan(Q_24h)) || ...
   any(isnan(price_e)) || any(isnan(pv_avail))
    error('输入数据中存在 NaN，请检查 dispatch_input.mat');
end

%% ==================== 2. 参数设置 ====================

% ---------- 2.1 动态碳信号映射：仅动态电网排放因子 ----------
Q_min = min(Q_24h);
Q_max = max(Q_24h);

if abs(Q_max - Q_min) < 1e-6
    Q_norm = zeros(T,1);
else
    Q_norm = double(Q_24h - Q_min) / double(Q_max - Q_min);
end

Q_norm = Q_norm(:);

mu_base = 0.5810; 
mu_grid = double(mu_base * (0.8 + 0.4 * Q_norm)); 
mu_grid = mu_grid(:);

lambda0 = 0.08;   % 原始基准碳价，保留用于记录

% ---------- 2.1.1 碳配额 + 超额递增边际阶梯碳价 ----------
% 结合当前系统排放量级（约1.2e5~1.3e5 kgCO2）设置
E_quota = 1.15e5;    % 免费碳配额 kgCO2

carbon_seg_width = [5000; 5000; 10000; 1e6];   % 各段宽度 kgCO2
carbon_seg_price =[0.08; 0.12; 0.18; 0.28];   % 各段边际碳价 元/kgCO2
N_seg = length(carbon_seg_width);

% ---------- 2.2 CHP参数 ----------
eta_chp_e = 0.30;
eta_chp_h = 0.50;
G_CHP_max = 5500;
ramp_CHP = 0.25 * G_CHP_max;

% ---------- 2.3 燃气锅炉参数 ----------
eta_GB = 0.90;
P_GB_max = 2500;
G_GB_max = P_GB_max / eta_GB;

% ---------- 2.4 燃气与碳排参数 ----------
c_gas = 0.35;
mu_gas = 0.202;

% ---------- 电储能参数 ----------
P_ES_ch_max = 1800;
P_ES_dis_max = 1800;
SOCe_min = 300;
SOCe_max = 3600;
SOCe_init = 1800;
eta_e_ch = 0.95;
eta_e_dis = 0.95;

% ---------- 热储能参数 ----------
P_HS_ch_max = 600;
P_HS_dis_max = 600;
SOCh_min = 500;
SOCh_max = 9000;
SOCh_init = 4500;
eta_h_ch = 0.92;
eta_h_dis = 0.92;

% ---------- 电需求响应参数 ----------
alpha_e = 0.10;
beta_e = 0.05;
c_shift = 0.05;
c_cut = 0.30;

% ---------- 热需求响应参数 ----------
alpha_h = 0.05;
beta_h = 0.03;
c_h_shift = 0.01;
c_h_cut = 0.10;

% ---------- 储能运行成本 ----------
c_es_e = 0.02;
c_es_h = 0.005;

% ---------- 第二阶段成本容忍度 ----------
epsilon_cost = 0.005;   % 允许总成本上浮0.5%

% ---------- 第二阶段目标权重 ----------
w_peakvalley = 1.0;     
w_gridsmooth = 0.20;    
w_gbpeak     = 0.30;    
w_gbsmooth   = 0.10;    

%% ==================== 3. 定义决策变量 ====================

% ---------- 电侧 ----------
P_grid = sdpvar(T,1);
P_PV   = sdpvar(T,1);

% ---------- CHP ----------
G_CHP   = sdpvar(T,1);
P_CHP_e = sdpvar(T,1);
P_CHP_h = sdpvar(T,1);

% ---------- 锅炉 ----------
G_GB   = sdpvar(T,1);
P_GB_h = sdpvar(T,1);

% ---------- 电储能 ----------
P_ES_ch  = sdpvar(T,1);
P_ES_dis = sdpvar(T,1);
SOC_e    = sdpvar(T,1);

% ---------- 热储能 ----------
P_HS_ch  = sdpvar(T,1);
P_HS_dis = sdpvar(T,1);
SOC_h    = sdpvar(T,1);

% ---------- 储能充放状态 ----------
u_ES = binvar(T,1);
u_HS = binvar(T,1);

% ---------- 电需求响应 ----------
P_e_shift     = sdpvar(T,1);
P_e_cut       = sdpvar(T,1);
P_e_shift_abs = sdpvar(T,1);
L_e_act       = sdpvar(T,1);

% ---------- 热需求响应 ----------
P_h_shift     = sdpvar(T,1);
P_h_cut       = sdpvar(T,1);
P_h_shift_abs = sdpvar(T,1);
L_h_act       = sdpvar(T,1);

% ---------- 碳配额/阶梯碳价变量 ----------
E_excess = sdpvar(1,1);
E_carbon_seg = sdpvar(N_seg,1);

% ---------- 第二阶段辅助变量：购电峰谷差 ----------
P_grid_peak   = sdpvar(1,1);
P_grid_valley = sdpvar(1,1);

% ---------- 第二阶段辅助变量：购电波动 ----------
dP_grid     = sdpvar(T-1,1);
dP_grid_abs = sdpvar(T-1,1);

% ---------- 第二阶段辅助变量：锅炉峰值 ----------
P_GB_peak = sdpvar(1,1);

% ---------- 第二阶段辅助变量：锅炉波动 ----------
dP_GB     = sdpvar(T-1,1);
dP_GB_abs = sdpvar(T-1,1);

%% ==================== 4. 构建约束 ====================
Constraints = [];

% ---------- 4.1 实际负荷定义 ----------
for k = 1:T
    Constraints = [Constraints, ...
        L_e_act(k) == load_e(k) + P_e_shift(k) + P_e_cut(k), ...
        L_h_act(k) == load_h(k) + P_h_shift(k) + P_h_cut(k)];
end

% ---------- 4.2 电功率平衡 ----------
for k = 1:T
    Constraints = [Constraints, ...
        P_grid(k) + P_PV(k) + P_CHP_e(k) + P_ES_dis(k) == ...
        L_e_act(k) + P_ES_ch(k)];
end

% ---------- 4.3 热功率平衡 ----------
for k = 1:T
    Constraints = [Constraints, ...
        P_CHP_h(k) + P_GB_h(k) + P_HS_dis(k) == ...
        L_h_act(k) + P_HS_ch(k)];
end

% ---------- 4.4 光伏约束 ----------
for k = 1:T
    Constraints = [Constraints, 0 <= P_PV(k) <= pv_avail(k)];
end

% ---------- 4.5 CHP约束 ----------
for k = 1:T
    Constraints = [Constraints, ...
        P_CHP_e(k) == eta_chp_e * G_CHP(k), ...
        P_CHP_h(k) == eta_chp_h * G_CHP(k), ...
        0 <= G_CHP(k) <= G_CHP_max];
end

for k = 2:T
    Constraints = [Constraints, ...
        -ramp_CHP <= G_CHP(k) - G_CHP(k-1) <= ramp_CHP];
end

% ---------- 4.6 锅炉约束 ----------
for k = 1:T
    Constraints = [Constraints, ...
        P_GB_h(k) == eta_GB * G_GB(k), ...
        0 <= P_GB_h(k) <= P_GB_max, ...
        0 <= G_GB(k) <= G_GB_max];
end

% ---------- 4.7 电储能约束 ----------
Constraints = [Constraints, ...
    SOC_e(1) == SOCe_init + eta_e_ch*P_ES_ch(1) - P_ES_dis(1)/eta_e_dis];

for k = 2:T
    Constraints = [Constraints, ...
        SOC_e(k) == SOC_e(k-1) + eta_e_ch*P_ES_ch(k) - P_ES_dis(k)/eta_e_dis];
end

for k = 1:T
    Constraints = [Constraints, ...
        SOCe_min <= SOC_e(k) <= SOCe_max, ...
        0 <= P_ES_ch(k) <= u_ES(k)*P_ES_ch_max, ...
        0 <= P_ES_dis(k) <= (1-u_ES(k))*P_ES_dis_max];
end

Constraints = [Constraints, SOC_e(T) == SOCe_init];

% ---------- 4.8 热储能约束 ----------
Constraints = [Constraints, ...
    SOC_h(1) == SOCh_init + eta_h_ch*P_HS_ch(1) - P_HS_dis(1)/eta_h_dis];

for k = 2:T
    Constraints = [Constraints, ...
        SOC_h(k) == SOC_h(k-1) + eta_h_ch*P_HS_ch(k) - P_HS_dis(k)/eta_h_dis];
end

for k = 1:T
    Constraints = [Constraints, ...
        SOCh_min <= SOC_h(k) <= SOCh_max, ...
        0 <= P_HS_ch(k) <= u_HS(k)*P_HS_ch_max, ...
        0 <= P_HS_dis(k) <= (1-u_HS(k))*P_HS_dis_max];
end

Constraints = [Constraints, SOC_h(T) == SOCh_init];

% ---------- 4.9 电需求响应约束 ----------
Constraints = [Constraints, sum(P_e_shift) == 0];

for k = 1:T
    Constraints = [Constraints, ...
        -alpha_e*load_e(k) <= P_e_shift(k) <= alpha_e*load_e(k), ...
        -beta_e*load_e(k) <= P_e_cut(k) <= 0];
end

% ---------- 4.10 热需求响应约束 ----------
Constraints = [Constraints, sum(P_h_shift) == 0];

for k = 1:T
    Constraints = [Constraints, ...
        -alpha_h*load_h(k) <= P_h_shift(k) <= alpha_h*load_h(k), ...
        -beta_h*load_h(k) <= P_h_cut(k) <= 0];
end

% ---------- 4.11 绝对值线性化 ----------
for k = 1:T
    Constraints = [Constraints, ...
        P_e_shift_abs(k) >= P_e_shift(k), ...
        P_e_shift_abs(k) >= -P_e_shift(k), ...
        P_h_shift_abs(k) >= P_h_shift(k), ...
        P_h_shift_abs(k) >= -P_h_shift(k)];
end

% ---------- 4.12 非负约束 ----------
Constraints = [Constraints, ...
    P_grid >= 0, ...
    P_e_shift_abs >= 0, ...
    P_h_shift_abs >= 0];

% ---------- 4.13 场景开关 ----------
if flag_DR == 0
    Constraints = [Constraints, ...
        P_e_shift == 0, P_e_cut == 0, ...
        P_h_shift == 0, P_h_cut == 0];
end

if flag_ES == 0
    Constraints = [Constraints, ...
        P_ES_ch == 0, P_ES_dis == 0, ...
        P_HS_ch == 0, P_HS_dis == 0];
end

% ---------- 4.14 第二阶段辅助约束 ----------
Constraints = [Constraints, ...
    P_grid <= P_grid_peak, ...
    P_grid >= P_grid_valley, ...
    P_grid_valley >= 0, ...
    P_GB_h <= P_GB_peak, ...
    P_GB_peak >= 0];

for k = 2:T
    Constraints = [Constraints, ...
        dP_grid(k-1) == P_grid(k) - P_grid(k-1), ...
        dP_grid_abs(k-1) >= dP_grid(k-1), ...
        dP_grid_abs(k-1) >= -dP_grid(k-1), ...
        dP_GB(k-1) == P_GB_h(k) - P_GB_h(k-1), ...
        dP_GB_abs(k-1) >= dP_GB(k-1), ...
        dP_GB_abs(k-1) >= -dP_GB(k-1)];
end

Constraints = [Constraints, dP_grid_abs >= 0, dP_GB_abs >= 0];

%% ==================== 5. 第一阶段目标：最小综合成本 ====================

C_ele = sum(price_e .* P_grid);

C_gas_chp = c_gas * sum(G_CHP);
C_gas_gb  = c_gas * sum(G_GB);
C_gas = C_gas_chp + C_gas_gb;

C_dr_e = c_shift * sum(P_e_shift_abs) - c_cut * sum(P_e_cut);
C_dr_h = c_h_shift * sum(P_h_shift_abs) - c_h_cut * sum(P_h_cut);
C_dr = C_dr_e + C_dr_h;
if flag_DR == 0
    C_dr = 0;
end

C_es_e = c_es_e * sum(P_ES_ch + P_ES_dis);
C_es_h = c_es_h * sum(P_HS_ch + P_HS_dis);
C_es_total = C_es_e + C_es_h;
if flag_ES == 0
    C_es_total = 0;
end

% ---------- 碳排放表达式 ----------
E_CO2_grid_expr  = sum(mu_grid .* P_grid);
E_CO2_gas_expr   = mu_gas * sum(G_CHP + G_GB);
E_CO2_total_expr = E_CO2_grid_expr + E_CO2_gas_expr;

% ---------- 碳配额 + 超额排放阶梯碳价约束 ----------
Constraints = [Constraints, ...
    E_excess >= E_CO2_total_expr - E_quota, ...
    E_excess >= 0, ...
    E_excess == sum(E_carbon_seg), ...
    0 <= E_carbon_seg <= carbon_seg_width];

% ---------- 阶梯碳成本 ----------
C_carbon = carbon_seg_price' * E_carbon_seg;

Objective_stage1 = C_ele + C_gas + C_dr + C_es_total + C_carbon;

%% ==================== 6. 第一阶段求解 ====================
ops = sdpsettings('solver','cplex','verbose',0);
sol1 = optimize(Constraints, Objective_stage1, ops);

if sol1.problem ~= 0
    warning(['第一阶段求解失败: ', sol1.info]);
    result.solve_success = 0;
    result.case_name = case_name;
    result.stage1_success = 0;
    result.stage2_success = 0;
    return;
end

Obj_stage1_best = value(Objective_stage1);

%% ==================== 7. 第二阶段目标：在成本接近最优前提下最小化峰谷与波动 ====================

Constraints_stage2 = Constraints;
Constraints_stage2 = [Constraints_stage2, Objective_stage1 <= (1 + epsilon_cost) * Obj_stage1_best];

Obj_peakvalley = P_grid_peak - P_grid_valley;
Obj_gridsmooth = sum(dP_grid_abs);
Obj_gbpeak     = P_GB_peak;
Obj_gbsmooth   = sum(dP_GB_abs);

Objective_stage2 = ...
    w_peakvalley * Obj_peakvalley + ...
    w_gridsmooth * Obj_gridsmooth + ...
    w_gbpeak     * Obj_gbpeak     + ...
    w_gbsmooth   * Obj_gbsmooth;

sol2 = optimize(Constraints_stage2, Objective_stage2, ops);

if sol2.problem ~= 0
    warning(['第二阶段求解失败，返回第一阶段结果: ', sol2.info]);
    stage2_ok = 0;
else
    stage2_ok = 1;
end

%% ==================== 8. 提取最终结果 ====================
if stage2_ok == 0
    sol1 = optimize(Constraints, Objective_stage1, ops);
end

P_grid_opt = value(P_grid);
P_PV_opt   = value(P_PV);

G_CHP_opt   = value(G_CHP);
P_CHP_e_opt = value(P_CHP_e);
P_CHP_h_opt = value(P_CHP_h);

G_GB_opt   = value(G_GB);
P_GB_h_opt = value(P_GB_h);

P_ES_ch_opt  = value(P_ES_ch);
P_ES_dis_opt = value(P_ES_dis);
SOC_e_opt    = value(SOC_e);

P_HS_ch_opt  = value(P_HS_ch);
P_HS_dis_opt = value(P_HS_dis);
SOC_h_opt    = value(SOC_h);

P_e_shift_opt = value(P_e_shift);
P_e_cut_opt   = value(P_e_cut);
L_e_act_opt   = value(L_e_act);

P_h_shift_opt = value(P_h_shift);
P_h_cut_opt   = value(P_h_cut);
L_h_act_opt   = value(L_h_act);

E_excess_opt     = value(E_excess);
E_carbon_seg_opt = value(E_carbon_seg);

C_ele_opt     = value(C_ele);
C_gas_opt     = value(C_gas);
C_gas_chp_opt = value(C_gas_chp);
C_gas_gb_opt  = value(C_gas_gb);
C_dr_opt      = value(C_dr);
C_es_opt      = value(C_es_total);
C_carbon_opt  = value(C_carbon);

Obj_solver_stage1_opt = value(Objective_stage1);
Obj_solver_stage2_opt = value(Objective_stage2);

E_CO2_grid_opt  = double(mu_grid)' * P_grid_opt;
E_CO2_gas_opt   = mu_gas * sum(G_CHP_opt + G_GB_opt);
E_CO2_total_opt = E_CO2_grid_opt + E_CO2_gas_opt;

P_grid_peak_opt    = value(P_grid_peak);
P_grid_valley_opt  = value(P_grid_valley);
Obj_peakvalley_opt = value(Obj_peakvalley);
Obj_gridsmooth_opt = value(Obj_gridsmooth);
P_GB_peak_opt      = value(P_GB_peak);
Obj_gbsmooth_opt   = value(Obj_gbsmooth);

%% ==================== 9. 整理结果 ====================
result.case_name = case_name;
result.flag_DR = flag_DR;
result.flag_ES = flag_ES;

result.solve_success = 1;
result.stage1_success = 1;
result.stage2_success = stage2_ok;

result.epsilon_cost = epsilon_cost;
result.w_peakvalley = w_peakvalley;
result.w_gridsmooth = w_gridsmooth;
result.w_gbpeak = w_gbpeak;
result.w_gbsmooth = w_gbsmooth;

result.C_ele = C_ele_opt;
result.C_gas = C_gas_opt;
result.C_gas_chp = C_gas_chp_opt;
result.C_gas_gb = C_gas_gb_opt;
result.C_dr = C_dr_opt;
result.C_es = C_es_opt;
result.C_carbon = C_carbon_opt;

result.Obj = C_ele_opt + C_gas_opt + C_dr_opt + C_es_opt + C_carbon_opt;
result.Obj_nocarbon = C_ele_opt + C_gas_opt + C_dr_opt + C_es_opt;

result.Obj_stage1_best = Obj_stage1_best;
result.Obj_stage1_final = Obj_solver_stage1_opt;
result.Obj_stage2 = Obj_solver_stage2_opt;

result.peak_valley_obj = Obj_peakvalley_opt;
result.grid_smooth_obj = Obj_gridsmooth_opt;
result.gb_peak_obj = P_GB_peak_opt;
result.gb_smooth_obj = Obj_gbsmooth_opt;

result.P_grid = P_grid_opt;
result.P_PV = P_PV_opt;

result.G_CHP = G_CHP_opt;
result.P_CHP_e = P_CHP_e_opt;
result.P_CHP_h = P_CHP_h_opt;

result.G_GB = G_GB_opt;
result.P_GB_h = P_GB_h_opt;

result.P_ES_ch = P_ES_ch_opt;
result.P_ES_dis = P_ES_dis_opt;
result.SOC_e = SOC_e_opt;

result.P_HS_ch = P_HS_ch_opt;
result.P_HS_dis = P_HS_dis_opt;
result.SOC_h = SOC_h_opt;

result.P_e_shift = P_e_shift_opt;
result.P_e_cut = P_e_cut_opt;
result.L_e_act = L_e_act_opt;

result.P_h_shift = P_h_shift_opt;
result.P_h_cut = P_h_cut_opt;
result.L_h_act = L_h_act_opt;

result.Q_24h = Q_24h;
result.Q_norm = Q_norm;
result.mu_grid = mu_grid;
result.mu_base = mu_base;
result.lambda0 = lambda0;
result.mu_gas = mu_gas;

% ---------- 阶梯碳价结果 ----------
result.E_quota = E_quota;
result.E_excess = E_excess_opt;
result.E_carbon_seg = E_carbon_seg_opt;
result.carbon_seg_width = carbon_seg_width;
result.carbon_seg_price = carbon_seg_price;

result.E_CO2_grid = E_CO2_grid_opt;
result.E_CO2_gas = E_CO2_gas_opt;
result.total_emission = E_CO2_total_opt;

result.peak_grid = max(P_grid_opt);
result.valley_grid = min(P_grid_opt);
result.peak_valley_diff = result.peak_grid - result.valley_grid;

result.grid_peak_from_var = P_grid_peak_opt;
result.grid_valley_from_var = P_grid_valley_opt;
result.GB_peak = max(P_GB_h_opt);

result.ele_balance_err = max(abs(P_grid_opt + P_PV_opt + P_CHP_e_opt + P_ES_dis_opt ...
    - L_e_act_opt - P_ES_ch_opt));

result.heat_balance_err = max(abs(P_CHP_h_opt + P_GB_h_opt + P_HS_dis_opt ...
    - L_h_act_opt - P_HS_ch_opt));

%% ==================== 10. 命令行输出 ====================
fprintf('\n========== 两阶段优化结果 ==========\n');
fprintf('场景名称: %s\n', case_name);
fprintf('第一阶段最优成本 Obj_stage1_best = %.2f\n', Obj_stage1_best);
fprintf('最终成本 Obj = %.2f\n', result.Obj);
fprintf('不含碳运行成本 Obj_nocarbon = %.2f\n', result.Obj_nocarbon);
fprintf('碳配额 E_quota = %.2f kgCO2\n', E_quota);
fprintf('总排放 E_total = %.2f kgCO2\n', result.total_emission);
fprintf('超额排放 E_excess = %.2f kgCO2\n', E_excess_opt);
fprintf('碳成本 C_carbon = %.2f 元\n', result.C_carbon);
fprintf('成本上浮比例 = %.4f %%\n', 100*(result.Obj - Obj_stage1_best)/Obj_stage1_best);
fprintf('购电峰值 = %.2f\n', result.peak_grid);
fprintf('购电谷值 = %.2f\n', result.valley_grid);
fprintf('购电峰谷差 = %.2f\n', result.peak_valley_diff);
fprintf('锅炉峰值 = %.2f\n', result.GB_peak);
fprintf('电储能放电总量 = %.2f\n', sum(P_ES_dis_opt));
fprintf('热储能放热总量 = %.2f\n', sum(P_HS_dis_opt));

fprintf('阶梯碳段分配 = ');
fprintf('%.2f ', E_carbon_seg_opt);
fprintf('\n');

%% ==================== 11. 可选绘图 ====================
myColors = { '#80D0E4', '#AAD498','#DD9F95','#568BC1','#BC9DA8','#A6C9C1'};
if flag_plot == 1

        %% 电侧供需构成
        figure('Name',['两阶段-电侧供需构成-', case_name]);
        % 堆叠柱状图，获取句柄并设置颜色、无边框
        b = bar(t, [P_PV_opt, P_CHP_e_opt, P_ES_dis_opt, P_grid_opt], 'stacked');
        for i = 1:4
            colorIdx = mod(i-1, numel(myColors)) + 1;
            set(b(i), 'FaceColor', myColors{colorIdx}, 'EdgeColor', 'none');
        end
        hold on;
        % 总需求虚线（细、无标记点，左右已贯通因t为全时段）
        plot(t, L_e_act_opt + P_ES_ch_opt, 'k--', 'LineWidth', 0.8);
        legend('光伏发电','CHP发电','电储能放电','电网购电','电侧总需求', 'FontSize', 14);
        xlabel('时段', 'FontSize', 14); ylabel('kW', 'FontSize', 14);
        grid on;

        %% 热侧供需构成
        figure('Name',['两阶段-热侧供需构成-', case_name]);
        b = bar(t, [P_CHP_h_opt, P_GB_h_opt, P_HS_dis_opt], 'stacked');
        for i = 1:3
            colorIdx = mod(i-1, numel(myColors)) + 1;
            set(b(i), 'FaceColor', myColors{colorIdx}, 'EdgeColor', 'none');
        end
        hold on;
        plot(t, L_h_act_opt + P_HS_ch_opt, 'k--', 'LineWidth', 0.8);
        legend('CHP供热','锅炉供热','热储能放热','热侧总需求', 'FontSize', 14);
        xlabel('时段', 'FontSize', 14); ylabel('kW', 'FontSize', 14);
        grid on;

    figure('Name',['两阶段-购电曲线-', case_name]);
    subplot(2,1,1);
    plot(t, P_grid_opt, 'b-o', 'LineWidth', 1.6);
    xlabel('时段'); ylabel('kW');
    title('电网购电功率曲线');
    grid on;

    subplot(2,1,2);
    stairs(1:T-1, value(dP_grid_abs), 'r-s', 'LineWidth', 1.4);
    xlabel('时段');
    ylabel('|ΔP_{grid}|');
    title('购电相邻时段波动');
    grid on;

    figure('Name',['两阶段-锅炉与热储能-', case_name]);
    yyaxis left;
    plot(t, P_GB_h_opt, 'r-o', 'LineWidth', 1.5);
    ylabel('锅炉供热/kW');

    yyaxis right;
    bar(t, P_HS_dis_opt);
    ylabel('热储能放热/kW');

    xlabel('时段');
    title('锅炉供热与热储能放热');
    legend('锅炉供热','热储能放热');
    grid on;

    figure('Name',['两阶段-动态碳信号-', case_name]);
    yyaxis left;
    plot(t, Q_norm, 'b-o', 'LineWidth', 1.5);
    ylabel('归一化碳信号', 'FontSize', 14);

    yyaxis right;
    plot(t, mu_grid, 'r-s', 'LineWidth', 1.5);
    ylabel('电网排放因子 kg/kWh', 'FontSize', 14);

    xlabel('时段');
    title('动态电网排放因子', 'FontSize', 14);
    legend('Q\_norm','\mu\_grid', 'FontSize', 14);
    grid on;

    % 新增：阶梯碳分段图
    figure('Name',['两阶段-阶梯碳成本分段-', case_name]);
    bar(E_carbon_seg_opt);
    xlabel('阶梯段');
    ylabel('kgCO2');
    title(['超额排放在各阶梯段中的分配 - ', case_name]);
    grid on;
    
        if flag_DR == 1
        figure('Name',['需求响应前后-电负荷对比-', ]);
        plot(t, load_e, 'r-o'); 
        hold on;
        plot(t, L_e_act_opt, 'b-o');
        legend('原始电负荷', '响应后电负荷', 'Location', 'best', 'FontSize', 14);
        xlabel('时段 (h)', 'FontSize', 14); ylabel('功率 (kW)', 'FontSize', 14);
        grid on; xlim([0 25]);
    end

    % 图4：需求响应前后热负荷对比图 (论文图 5-7)
    if flag_DR == 1
        figure('Name',['需求响应前后-热负荷对比', ]);
        plot(t, load_h, 'r--o');
        hold on;
        plot(t, L_h_act_opt, 'b-o');
        legend('原始热负荷', '响应后热负荷', 'Location', 'best', 'FontSize', 14);
        xlabel('时段 (h)', 'FontSize', 14); ylabel('功率 (kW)', 'FontSize', 14);
        grid on; xlim([0 25]);
    end
end

end