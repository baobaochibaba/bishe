%% OCO-3 卫星数据处理：典型日24小时排放通量序列生成
 

clear; clc; close all;
 
%% ==================== 用户设定区 ====================
% 1. 数据文件夹路径
dataFolder = 'C:\Users\ASUS\Desktop\oco';  
 
% 2. 研究区域经纬度范围
lon_min = 116.0; lon_max = 117.0;   % 经度范围
lat_min = 39.5;  lat_max = 40.5;    % 纬度范围
 
% 3. 排放源位置
x_source = 116.5;   % 经度
y_source = 39.8;    % 纬度
H_source = 100;      % 有效源高（米），根据烟囱高度估计
 

 
% 初始化存储每个事件 XCO2 数据的 cell 数组
event_xco2 = {};   % 每个元素是一个向量，包含该事件所有观测点的 xco2 值
event_lon = {};   % 存储每个事件的所有观测点经度
event_lat = {};   % 存储每个事件的所有观测点纬度
% 5. 质量筛选参数（可根据需要放宽，但建议保留基本筛选）
allowed_qf = 0;                % 允许的质量标志值（0=好，1=边缘）
max_uncertainty = 1.5;              % 最大允许的不确定度 (ppm)
 
% 6. 异常值剔除参数（基于四分位距）
iqr_multiplier = 3;                 % 超过中位数 ± iqr_multiplier * IQR 的视为异常
 
% 7. 负荷数据文件（可选，用于按比例分配日内变化）
use_load_data = true;                % 是否使用负荷数据（true/false）
loadFile = 'carbon+DR数据.xlsx';     % 负荷数据文件路径（如果 use_load_data 为 true）
% 假设 Excel 中第 2 行是电负荷，第 3 行是热负荷，单位 kW
load_e = xlsread(loadFile, 1, 'A2:Y2');   % 读取电负荷（24小时）
load_h = xlsread(loadFile, 1, 'A3:Y3');   % 读取热负荷（24小时）
total_load = load_e + load_h;              % 总负荷（kW），用于缩放
 
% 8. 输出文件保存路径
outputFile = 'typical_days_sequences.mat';
 
%% ==================== 预读取 ERA5 气象数据 ====================
era5_file = 'C:\Users\ASUS\Desktop\oco\era11.nc';   % 你的 ERA5 文件路径
lon_era5 = ncread(era5_file, 'longitude');
lat_era5 = ncread(era5_file, 'latitude');
time_era5_raw = ncread(era5_file, 'valid_time');
% 时间转换（seconds since 1970-01-01）
time_era5 = datenum(1970,1,1) + time_era5_raw / 86400;
u10_all = ncread(era5_file, 'u10');   % 维度 [lon, lat, time]
v10_all = ncread(era5_file, 'v10');
t2m_all = ncread(era5_file, 't2m');   % 2m温度 (K)
tcc_all = ncread(era5_file, 'tcc');   % 总云量 (0-1)
blh_all = ncread(era5_file, 'blh');   % 边界层高度 (m)
fprintf('ERA5 数据读取完成：经度 %d 个，纬度 %d 个，时间 %d 个\n', ...
    length(lon_era5), length(lat_era5), length(time_era5));


%% ==================== 批量读取与反演 ====================
% 获取文件夹下所有 .nc4 文件
fileList = dir(fullfile(dataFolder, '*.nc4'));
fprintf('共找到 %d 个 .nc4 文件\n', length(fileList));
 
% 初始化存储反演结果的表格
results = table();   % 包含两列：time (datenum), Q (吨/小时)
 
% 循环处理每个文件
for i = 1:length(fileList)
    filename = fullfile(dataFolder, fileList(i).name);
    fprintf('正在处理第 %d/%d 个文件：%s\n', i, length(fileList), fileList(i).name);
    
    % 读取核心变量
    try
        lat = ncread(filename, '/latitude');
        lon = ncread(filename, '/longitude');
        xco2 = ncread(filename, '/xco2');
        xco2_uncert = ncread(filename, '/xco2_uncertainty');
        time_raw = ncread(filename, '/time');
        qf = ncread(filename, '/xco2_quality_flag');
    catch ME
        warning('文件 %s 读取核心变量失败：%s', fileList(i).name, ME.message);
        continue;
    end
    
    % 时间转换（已知参考日期为 1970-01-01）
    ref_date = datenum(1970, 1, 1);
    time_matlab = ref_date + time_raw / 86400;
    
    % 空间筛选
    in_region = (lon >= lon_min) & (lon <= lon_max) & ...
                (lat >= lat_min) & (lat <= lat_max);
    if sum(in_region) == 0
        continue;   % 该文件无区域观测
    end
    
    % 质量筛选：允许的质量标志 + 不确定度上限
    good_qf = ismember(qf, allowed_qf);
    good_uncert = xco2_uncert <= max_uncertainty;
    good = good_qf & good_uncert & in_region;
    
    if sum(good) == 0
        continue;
    end
    
    % 提取筛选后的数据
    lat_g = lat(good);
    lon_g = lon(good);
    xco2_g = xco2(good);
    time_g = time_matlab(good);
    
    % 按时间连续性分组（同一过境事件）
    [time_g, sort_idx] = sort(time_g);
    lat_g = lat_g(sort_idx);
    lon_g = lon_g(sort_idx);
    xco2_g = xco2_g(sort_idx);
    
    dt = diff(time_g) * 24 * 60;   % 时间差（分钟）
    group_id = ones(size(time_g));
    gid = 1;
    for k = 2:length(time_g)
        if dt(k-1) > 10   % 间隔超过10分钟视为不同过境
            gid = gid + 1;
        end
        group_id(k) = gid;
    end
    
    % 对每个过境组进行反演
    unique_groups = unique(group_id);
    for g = 1:length(unique_groups)
        idx = (group_id == unique_groups(g));
        if sum(idx) < 3
            continue;   % 点数太少，反演不稳定
        end
        t_group = mean(time_g(idx));
        % 提取该事件的所有观测点坐标和浓度
        x_obs = lon_g(idx);
        y_obs = lat_g(idx);
        c_obs = xco2_g(idx);
        
         % 从ERA5提取对应时刻和位置的数据
        [~, time_idx] = min(abs(time_era5 - t_group));
        [~, lon_idx] = min(abs(lon_era5 - x_source));
        [~, lat_idx] = min(abs(lat_era5 - y_source));

        u_val = u10_all(lon_idx, lat_idx, time_idx);
        v_val = v10_all(lon_idx, lat_idx, time_idx);
        t2m_val = t2m_all(lon_idx, lat_idx, time_idx);
        tcc_val = tcc_all(lon_idx, lat_idx, time_idx);
        blh_val = blh_all(lon_idx, lat_idx, time_idx);

        % 计算风速风向
        wind_speed = sqrt(u_val^2 + v_val^2);
        wind_dir_math = atan2d(v_val, u_val);
        wind_dir_met = mod(90 - wind_dir_math, 360);

        % 更新met结构体
        met.u = max(wind_speed, 0.5);
        met.wdir = wind_dir_met;
        met.pblh = max(blh_val, 50);             % 边界层高度 (m)，避免过小
        % 动态计算大气稳定度
        met.stab_class = get_pasquill_stability(y_source, x_source, t_group, wind_speed, tcc_val);
        % 调用高斯烟羽反演函数（简化版）
        Q_est = gaussian_plume_inversion_full(x_obs, y_obs, c_obs, ...
                                       x_source, y_source, H_source, met);
        if ~isnan(Q_est) && Q_est > 0
            newRow = table(t_group, Q_est, 'VariableNames', {'time', 'Q'});
            results = [results; newRow];
            % 保存该事件的所有 XCO2 观测值
            event_xco2{end+1} = xco2_g(idx);   % idx 是当前事件在分组中的索引
            event_lon{end+1} = lon_g(idx);
            event_lat{end+1} = lat_g(idx);
        end
    end
end
 
fprintf('反演完成，共获得 %d 次有效过境事件\n', height(results));
if height(results) == 0
    error('没有有效过境事件，请检查区域范围或筛选条件。');
end
 
%% ==================== 异常值剔除 ====================
Q_values = results.Q;
Q_median = median(Q_values);
Q_iqr = iqr(Q_values);
lower_bound = Q_median - iqr_multiplier * Q_iqr;
upper_bound = Q_median + iqr_multiplier * Q_iqr;
valid = (Q_values >= lower_bound) & (Q_values <= upper_bound);
results = results(valid, :);
fprintf('异常值剔除后剩余 %d 次有效事件\n', height(results));
 

%% ==================== 所有有效事件的观测点与反演数据 ===================

figure('Name', '观测点空间分布');
hold on;
colors = lines(length(event_lon));
for e = 1:length(event_lon)
    scatter(event_lon{e}, event_lat{e}, 20, colors(e,:), 'filled', ...
        'DisplayName', ['事件 ', datestr(results.time(e), 'mm-dd')]);
end
scatter(x_source, y_source, 100, 'r^', 'filled', 'DisplayName', '源点');
xlabel('经度'); ylabel('纬度');
legend('Location', 'best');
title('所有有效事件观测点分布');
grid on;
hold off;

% -------------------- 2. 所有事件 XCO2 箱线图 --------------------
if length(event_xco2) >= 2
    figure('Name', '所有事件XCO2箱线图');
    % 将 cell 转换为矩阵（填充 NaN）
    max_len = max(cellfun(@length, event_xco2));
    xco2_matrix = NaN(length(event_xco2), max_len);
    for i = 1:length(event_xco2)
        xco2_matrix(i, 1:length(event_xco2{i})) = event_xco2{i};
    end
    boxplot(xco2_matrix', 'Labels', cellstr(datestr(results.time, 'mm-dd')));
    xlabel('事件日期'); ylabel('XCO₂ (ppm)');
    title('各事件 XCO₂ 浓度分布对比');
    grid on;
else
    warning('有效事件少于2个，无法绘制箱线图');
end
%% ==================== 选择要生成的典型日 ====================
% 用户指定要生成哪一天（格式 'yyyy-mm-dd'）
target_date_str = '2023-2-08';   % 改为你需要的日期
target_date = datenum(target_date_str, 'yyyy-mm-dd');

% 提取所有事件日期
event_dates = floor(results.time);
unique_dates = unique(event_dates);

% 检查该日期是否在有效事件中
if ~ismember(target_date, unique_dates)
    error('指定日期 %s 不在有效事件日期中，可选日期：%s', target_date_str, datestr(unique_dates));
end

% 找出该日期对应的事件索引
idx_date = (event_dates == target_date);
if sum(idx_date) > 1
    Q_daily = mean(results.Q(idx_date));
    fprintf('日期 %s 有 %d 个事件，取平均 Q = %.2f 吨/小时\n', ...
        datestr(target_date), sum(idx_date), Q_daily);
else
    Q_daily = results.Q(idx_date);
end

% 生成24小时序列
if use_load_data
    scale = total_load / mean(total_load);   % 归一化比例
    Q_24h = Q_daily * scale;
else
    Q_24h = Q_daily * ones(24, 1);
end

% 保存结果（可以只保存这个序列，也可以保持结构体但只含一天）
typical_days = struct();
typical_days.date = target_date;
typical_days.Q_24h = Q_24h;        % 24×1 向量
if use_load_data
    typical_days.load_used = total_load;
end


% 保存到文件
save('typical_day_one.mat', 'typical_days');
fprintf('已保存日期 %s 的24小时序列\n', datestr(target_date));
 
%% ==================== 可视化典型日 ====================
% 假设已定义：
%   target_date_str, target_date   （用户选定的典型日）
%   results 表（包含 time, Q）
%   event_xco2 元胞数组（每个事件的所有XCO2值）
%   load_e, load_h, total_load    （负荷数据）
%   x_source, y_source             （源点坐标）
%   obs_lon, obs_lat               （每个事件的所有观测点经纬度，已在前面收集）



% -------------------- 选定典型日的 XCO2 沿轨分布图 --------------------
% 找到选定日期在 results 中的索引
target_idx = find(floor(results.time) == target_date, 1);
if isempty(target_idx)
    warning('选定日期 %s 没有对应的有效事件，无法绘制沿轨分布图', target_date_str);
else
    figure('Name', 'XCO2沿轨分布');
    x_vals = 1:length(event_xco2{target_idx});
    plot(x_vals, event_xco2{target_idx}, 'bo-', 'MarkerSize', 6, 'LineWidth', 1.2);
    xlabel('观测点序号 (沿轨方向)'); ylabel('XCO₂ (ppm)');
    title(['XCO₂ 沿轨分布 (', datestr(target_date, 'yyyy-mm-dd'), ')']);
    grid on;
    % 标注背景浓度（最小值）
    c_bg = min(event_xco2{target_idx});
    hold on;
    yline(c_bg, 'r--', 'LineWidth', 1.5, 'DisplayName', sprintf('背景浓度 = %.1f ppm', c_bg));
    legend;
    hold off;
end

% -------------------- 4. 负荷曲线图--------------------
figure('Name', '典型日负荷曲线');
plot(0:23, load_e, 'b-', 'LineWidth', 1.5, 'DisplayName', '电负荷');
hold on;
plot(0:23, load_h, 'r-', 'LineWidth', 1.5, 'DisplayName', '热负荷');
plot(0:23, total_load, 'k--', 'LineWidth', 1.5, 'DisplayName', '总负荷');
xlabel('小时'); ylabel('负荷 (kW)');
legend('Location', 'best');
title('典型日24小时负荷曲线');
grid on;
xlim([-0.5 23.5]);

% -------------------- 5. 选定典型日的24小时排放通量图 --------------------
% 注意：假设 typical_days 已生成（只包含选定日期）
if exist('typical_days', 'var') && isfield(typical_days, 'Q_24h')
    figure('Name', '选定典型日排放通量');
    bar(0:23, typical_days.Q_24h, 'FaceColor', [0.2 0.6 0.9]);
    xlabel('小时'); ylabel('排放通量 (吨/小时)');
    title(['24小时排放通量 (', datestr(target_date, 'yyyy-mm-dd'), ')']);
    grid on;
    xlim([-0.5 23.5]);
else
    warning('未找到 typical_days 变量或 Q_24h 字段，请先生成选定典型日的24小时序列');
end

fprintf('所有图表绘制完成。\n'); 
%% ==================== 保存结果 ====================
% 同时保存一个便于调度模型读取的表格（可选）
% 例如，将每个日期和对应的24小时序列存入结构体
save(outputFile, 'typical_days');
fprintf('结果已保存至：%s\n', outputFile);
 
% 也可生成一个文本文件或Excel，方便查看
% 此处简单生成一个文本说明
fid = fopen('typical_days_info.txt', 'w');
fprintf(fid, '典型日排放通量信息\n');
fprintf(fid, '日期\t\t代表Q(吨/小时)\t24小时序列(吨/小时)\n');

fclose(fid);
fprintf('文本信息已保存至 typical_days_info.txt\n');
 
%% ==================== 子函数：高斯烟羽反演 ====================
function Q = gaussian_plume_inversion_full(x_obs, y_obs, c_obs, x_src, y_src, H, met)
% 完整版高斯烟羽反演函数（支持大气稳定度、烟羽抬升等）
% 输入：
%   x_obs, y_obs : 观测点经度/纬度（度）
%   c_obs        : 观测 XCO2（ppm）
%   x_src, y_src : 源点经纬度
%   H            : 烟囱几何高度（m）
%   met          : 气象数据结构体，包含以下字段：
%       .u          : 风速 (m/s) —— 可以是地面10m风速，或有效输送风速
%       .wdir       : 风向（度），气象学定义（风的来向）
%       .stab_class : 大气稳定度等级，字符，可取 'A','B','C','D','E','F'（默认 'D'）
%       .pblh       : 边界层高度（m）（可选，用于判断扩散受限）
% 输出：
%   Q            : 排放通量（吨/小时）
 
    % ---------- 1. 默认值处理 ----------
    if nargin < 7
        error('需要传入气象数据结构体 met');
    end

 
 
    % ---------- 2. 常数 ----------
    ppm_to_kgm3 = 1.0e-6 * 44.01 / 28.97 * 1.2;  % ppm -> kg/m?
 
    % ---------- 3. 坐标转换（经纬度转米）----------
    deg2m_lat = 111320;                % 1°纬度 ≈ 111.32 km
    deg2m_lon = 111320 * cosd(mean(y_obs));
    x_m = (x_obs - x_src) * deg2m_lon;
    y_m = (y_obs - y_src) * deg2m_lat;
 
    % ---------- 4. 风向转换与旋转 ----------
    wind_rad = (270 - met.wdir) * pi/180;   % 气象风向转数学角
    x_rot =  x_m * cos(wind_rad) + y_m * sin(wind_rad);
    y_rot = -x_m * sin(wind_rad) + y_m * cos(wind_rad);
 
    % 只考虑下风方向点
    downwind = x_rot > 0;
    if sum(downwind) < 2
        Q = NaN;
        return;
    end
    x_rot = x_rot(downwind);
    y_rot = y_rot(downwind);
    c_obs = c_obs(downwind);
 
    % ---------- 5. 背景浓度估算 ----------
    c_bg = min(c_obs);
    delta_c = c_obs - c_bg;                % ppm
    delta_c_kgm3 = delta_c * ppm_to_kgm3;   % kg/m?
 
    % ---------- 6. 根据稳定度计算扩散参数 ----------
    % 使用 Briggs 城市扩散参数（常用经验公式）
    % 不同稳定度对应不同的系数，这里简化为一个查表结构
    [sigma_y_func, sigma_z_func] = get_briggs_coeff(met.stab_class, 'urban');
 
    sigma_y = sigma_y_func(x_rot);
    sigma_z = sigma_z_func(x_rot);
 
    % 可选的边界层限制：如果 sigma_z 超过边界层高度，则截断（简化处理）
    sigma_z = min(sigma_z, met.pblh / 2.15);   % 经验处理
 
    % ---------- 7. 高斯烟羽反演 ----------
    denominator = exp(-y_rot.^2 ./ (2*sigma_y.^2));
    denominator(denominator < 1e-6) = 1e-6;
    Q_est = delta_c_kgm3 .* (2*pi*met.u.*sigma_y.*sigma_z) ./ denominator;   % kg/s
 
    % ---------- 8. 综合与单位转换 ----------
    Q_median = median(Q_est, 'omitnan');
    Q = Q_median * 3.6;   % kg/s -> 吨/小时
 
end
 

function [sigma_y_func, sigma_z_func] = get_briggs_coeff(stab_class, terrain)
    % 根据稳定度和地形返回 sigma_y 和 sigma_z 的函数句柄
    switch upper(stab_class)
        case 'A'
            sigma_y_func = @(x) 0.32 * x .* (1 + 0.0004*x).^(-0.5);
            sigma_z_func = @(x) 0.24 * x .* (1 + 0.001*x).^(0.5);
        case 'B'
            sigma_y_func = @(x) 0.32 * x .* (1 + 0.0004*x).^(-0.5);
            sigma_z_func = @(x) 0.24 * x .* (1 + 0.001*x).^(0.5);
        case 'C'
            sigma_y_func = @(x) 0.22 * x .* (1 + 0.0004*x).^(-0.5);
            sigma_z_func = @(x) 0.20 * x;
        case 'D'
            sigma_y_func = @(x) 0.16 * x .* (1 + 0.0004*x).^(-0.5);
            sigma_z_func = @(x) 0.14 * x .* (1 + 0.0003*x).^(-0.5);
        case 'E'
            sigma_y_func = @(x) 0.11 * x .* (1 + 0.0004*x).^(-0.5);
            sigma_z_func = @(x) 0.08 * x .* (1 + 0.0015*x).^(-0.5);
        case 'F'
            sigma_y_func = @(x) 0.11 * x .* (1 + 0.0004*x).^(-0.5);
            sigma_z_func = @(x) 0.06 * x .* (1 + 0.0015*x).^(-0.5);
        otherwise
            error('未知稳定度等级：%s', stab_class);
    end
end

%% ==================== 子函数：计算Pasquill稳定度等级 ====================
function stab = get_pasquill_stability(lat, lon, time_datenum, u10, tcc)
% 输入：
%   lat, lon       : 纬度、经度（度）
%   time_datenum   : MATLAB datenum (UTC)
%   u10            : 10米风速 (m/s)
%   tcc            : 总云量 (0-1)
% 输出：
%   stab           : 稳定度字符 'A'~'F'

    % 1. 计算太阳高度角
    h = solar_altitude(lat, lon, time_datenum);
    
    % 2. 确定太阳辐射等级 (0-4)
    if h <= 0   % 夜间
        rad_class = 0;
    else
        % 白天：根据太阳高度角和云量查表
        if h >= 60
            if tcc <= 0.5
                rad_class = 4;
            else
                rad_class = 3;
            end
        elseif h >= 35
            if tcc <= 0.5
                rad_class = 3;
            else
                rad_class = 2;
            end
        elseif h >= 15
            if tcc <= 0.5
                rad_class = 2;
            else
                rad_class = 1;
            end
        else % h < 15
            rad_class = 1;
        end
    end
    
    % 3. 根据辐射等级和风速确定稳定度 (Pasquill)
    if rad_class == 0   % 夜间
        if tcc >= 0.8
            stab = 'D';
        else
            if u10 <= 2
                stab = 'F';
            elseif u10 <= 3
                stab = 'E';
            elseif u10 <= 5
                stab = 'D';
            else
                stab = 'D';
            end
        end
    else
        % 白天
        if rad_class == 1
            if u10 <= 1.5
                stab = 'A';
            elseif u10 <= 2.5
                stab = 'B';
            elseif u10 <= 4.5
                stab = 'C';
            else
                stab = 'D';
            end
        elseif rad_class == 2
            if u10 <= 1.5
                stab = 'A';
            elseif u10 <= 2.5
                stab = 'B';
            elseif u10 <= 4.5
                stab = 'C';
            else
                stab = 'D';
            end
        elseif rad_class == 3
            if u10 <= 1.5
                stab = 'B';
            elseif u10 <= 2.5
                stab = 'C';
            elseif u10 <= 4.5
                stab = 'D';
            else
                stab = 'D';
            end
        else % rad_class == 4
            if u10 <= 1.5
                stab = 'C';
            elseif u10 <= 2.5
                stab = 'D';
            elseif u10 <= 4.5
                stab = 'D';
            else
                stab = 'D';
            end
        end
    end
end

%% 子函数：计算太阳高度角
function h = solar_altitude(lat, lon, time_datenum)
    % 输入：纬度、经度（度），UTC时间（datenum）
    % 输出：太阳高度角（度）
    % 算法参考：https://www.psa.es/sdg/sunpos.htm
    d = time_datenum - datenum(2000,1,1,0,0,0);   % 儒略日（简化）
    n = d;  % 从2000-01-01起的天数
    
    % 太阳赤纬角 (度)
    obliquity = 23.439;   % 黄赤交角
    lambda = 280.46 + 0.9856474 * n;   % 太阳平黄经
    delta = asind(sind(obliquity) * sind(lambda));
    
    % 时角 (度)
    % 首先计算格林尼治恒星时角（简化）
    GMST = 280.46061837 + 360.98564736629 * n;
    hour_angle = mod(GMST + lon - 360 * (time_datenum - floor(time_datenum)), 360);
    
    % 太阳高度角
    h = asind(sind(lat) * sind(delta) + cosd(lat) * cosd(delta) * cosd(hour_angle));
end

 

