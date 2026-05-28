%% OCO-3 卫星数据处理：四天观测展示 + 指定典型日反演 + 24小时排放通量序列生成

clear; clc; close all;

%% ==================== 用户设定区 ====================
% 1. 数据文件夹路径（oco卫星数据地址）
dataFolder = 'C:\Users\ASUS\Desktop\oco';  

% 2. 研究区域经纬度范围
lon_min = 107.6; lon_max = 109.5;   % 经度范围
lat_min = 33.7;  lat_max = 34.75;   % 纬度范围

% 3. 排放源位置
x_source = 108.88;   % 经度
y_source = 34.19;    % 纬度

% 4. 指定只反演的日期
target_date_str = '2022-02-24';
target_date = datenum(target_date_str, 'yyyy-mm-dd');

% 5. 质量筛选参数
allowed_qf = 0;              % 允许的质量标志值（0=好）
max_uncertainty = 1.5;       % 最大允许的不确定度 (ppm)

% 6. 异常值剔除参数（基于四分位距）
iqr_multiplier = 3;

% 7. 负荷数据文件
use_load_data = true;
loadFile = 'carbon+DR数据.xlsx';
load_e = xlsread(loadFile, 1, 'A2:X2');   % 电负荷（24小时）
load_h = xlsread(loadFile, 1, 'A3:X3');   % 热负荷（24小时）
total_load = load_e + load_h;

% 8. 输出文件保存路径
outputFile = 'typical_days_sequences.mat';

%% ==================== 初始化变量 ====================
% ---- 所有日期观测事件（仅用于展示）----
all_event_xco2 = {};
all_event_lon  = {};
all_event_lat  = {};
all_event_time = [];   % 每个事件的平均时间

% ---- 目标日期有效反演事件（用于反演和后续图）----
event_xco2 = {};
event_lon  = {};
event_lat  = {};
results = table();   % 包含 time, Q

%% ==================== 预读取 ERA5 气象数据 ====================
era5_file = 'C:\Users\ASUS\Desktop\oco\era11.nc';%气象数据文件地址
lon_era5 = ncread(era5_file, 'longitude');
lat_era5 = ncread(era5_file, 'latitude');
time_era5_raw = ncread(era5_file, 'valid_time');

% 时间转换
time_era5 = datenum(1970,1,1) + time_era5_raw / 86400;

u10_all = ncread(era5_file, 'u10');
v10_all = ncread(era5_file, 'v10');
t2m_all = ncread(era5_file, 't2m');
tcc_all = ncread(era5_file, 'tcc');
blh_all = ncread(era5_file, 'blh');

fprintf('ERA5 数据读取完成：经度 %d 个，纬度 %d 个，时间 %d 个\n', ...
    length(lon_era5), length(lat_era5), length(time_era5));

%% ==================== 批量读取 OCO-3 文件 ====================
fileList = dir(fullfile(dataFolder, '*.nc4'));
fprintf('共找到 %d 个 .nc4 文件\n', length(fileList));

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

    % 时间转换
    ref_date = datenum(1970, 1, 1);
    time_matlab = ref_date + time_raw / 86400;

    % 空间筛选
    in_region = (lon >= lon_min) & (lon <= lon_max) & ...
                (lat >= lat_min) & (lat <= lat_max);
    if sum(in_region) == 0
        continue;
    end

    % 质量筛选
    good_qf = ismember(qf, allowed_qf);
    good_uncert = xco2_uncert <= max_uncertainty;
    good = good_qf & good_uncert & in_region;

    if sum(good) == 0
        continue;
    end

    % 提取筛选后数据
    lat_g = lat(good);
    lon_g = lon(good);
    xco2_g = xco2(good);
    time_g = time_matlab(good);

    % 按时间排序
    [time_g, sort_idx] = sort(time_g);
    lat_g = lat_g(sort_idx);
    lon_g = lon_g(sort_idx);
    xco2_g = xco2_g(sort_idx);

    % 按时间连续性分组（同一过境事件）
    dt = diff(time_g) * 24 * 60;   % 分钟
    group_id = ones(size(time_g));
    gid = 1;
    for k = 2:length(time_g)
        if dt(k-1) > 10
            gid = gid + 1;
        end
        group_id(k) = gid;
    end

    unique_groups = unique(group_id);

    for g = 1:length(unique_groups)
        idx = (group_id == unique_groups(g));

        if sum(idx) < 3
            continue;
        end

        t_group = mean(time_g(idx));

        % 当前事件观测值
        x_obs = lon_g(idx);
        y_obs = lat_g(idx);
        c_obs = xco2_g(idx);


        all_event_time(end+1,1) = t_group;
        all_event_xco2{end+1,1} = c_obs;
        all_event_lon{end+1,1}  = x_obs;
        all_event_lat{end+1,1}  = y_obs;


        if floor(t_group) ~= target_date
            continue;
        end

        % 从ERA5提取对应时刻和位置的数据
        [~, time_idx] = min(abs(time_era5 - t_group));
        [~, lon_idx] = min(abs(lon_era5 - x_source));
        [~, lat_idx] = min(abs(lat_era5 - y_source));

        % ERA5时间匹配检查
        time_diff_hour = abs(time_era5(time_idx) - t_group) * 24;
        if time_diff_hour > 1.5
            warning('事件时间 %s 与最近ERA5时间 %s 相差 %.2f 小时，跳过该事件。', ...
                datestr(t_group), datestr(time_era5(time_idx)), time_diff_hour);
            continue;
        end

        u_val = u10_all(lon_idx, lat_idx, time_idx);
        v_val = v10_all(lon_idx, lat_idx, time_idx);
        t2m_val = t2m_all(lon_idx, lat_idx, time_idx); %#ok<NASGU>
        tcc_val = tcc_all(lon_idx, lat_idx, time_idx);
        blh_val = blh_all(lon_idx, lat_idx, time_idx);

        % 风速风向
        wind_speed = sqrt(u_val^2 + v_val^2);
        wind_dir_met = mod(270 - atan2d(v_val, u_val), 360);

        % 气象结构体
        met.u = max(wind_speed, 0.5);
        met.wdir = wind_dir_met;
        met.pblh = max(blh_val, 50);
        met.stab_class = get_pasquill_stability(y_source, x_source, t_group, wind_speed, tcc_val);

        % 高斯烟羽反演
        Q_est = gaussian_plume_inversion_full(x_obs, y_obs, c_obs, ...
                    x_source, y_source, met);

        if ~isnan(Q_est) && Q_est > 0
            newRow = table(t_group, Q_est, 'VariableNames', {'time', 'Q'});
            results = [results; newRow];

            event_xco2{end+1,1} = c_obs;
            event_lon{end+1,1}  = x_obs;
            event_lat{end+1,1}  = y_obs;
        end
    end
end

fprintf('所有日期观测事件共识别 %d 个\n', length(all_event_time));
fprintf('目标日期 %s 反演完成，共获得 %d 次有效过境事件\n', ...
    datestr(target_date, 'yyyy-mm-dd'), height(results));

if isempty(all_event_time)
    error('没有识别到任何观测事件，请检查区域范围或筛选条件。');
end

if height(results) == 0
    error('目标日期 %s 没有有效反演事件，请检查ERA5时间范围、区域范围和筛选条件。', target_date_str);
end

%% ==================== 异常值剔除 ====================
Q_values = results.Q;
Q_median = median(Q_values);
Q_iqr = iqr(Q_values);
lower_bound = Q_median - iqr_multiplier * Q_iqr;
upper_bound = Q_median + iqr_multiplier * Q_iqr;
valid = (Q_values >= lower_bound) & (Q_values <= upper_bound);

results = results(valid, :);
event_xco2 = event_xco2(valid);
event_lon = event_lon(valid);
event_lat = event_lat(valid);

fprintf('异常值剔除后，目标日期剩余 %d 次有效事件\n', height(results));

if height(results) == 0
    error('目标日期 %s 的反演结果在异常值剔除后为空。', target_date_str);
end

%% ==================== 图1：四天所有观测事件空间分布图 ====================
figure('Name', '四天所有观测事件空间分布');
hold on;

all_dates_floor = floor(all_event_time);
unique_all_dates = unique(all_dates_floor);
colors_all = lines(length(unique_all_dates));

for d = 1:length(unique_all_dates)
    idx_d = (all_dates_floor == unique_all_dates(d));
    for j = find(idx_d)'
        % 关键1：事件点不进入图例
        scatter(all_event_lon{j}, all_event_lat{j}, 16, colors_all(d,:), 'filled', ...
            'HandleVisibility', 'off');
    end
end

% 关键2：虚拟点的图例文字改为“事件1”“事件2”……
for d = 1:length(unique_all_dates)
    scatter(NaN, NaN, 30, colors_all(d,:), 'filled', ...
        'DisplayName', sprintf('事件%d', d));
end

scatter(x_source, y_source, 120, 'r^', 'filled', 'DisplayName', '源点');
xlabel('经度');
ylabel('纬度');
legend('Location', 'best', 'FontSize', 14);
grid on;
hold off;

%% ==================== 四天观测日期统计 ====================
disp('识别到的观测日期及事件数：');
for d = 1:length(unique_all_dates)
    n_d = sum(all_dates_floor == unique_all_dates(d));
    fprintf('%s : %d 个事件\n', datestr(unique_all_dates(d), 'yyyy-mm-dd'), n_d);
end

%% ==================== 目标日期有效反演事件空间分布 ====================
figure('Name', '目标日期有效反演事件观测点分布');
hold on;
colors = lines(length(event_lon));
for e = 1:length(event_lon)
    scatter(event_lon{e}, event_lat{e}, 20, colors(e,:), 'filled', ...
        'DisplayName', ['事件 ', datestr(results.time(e), 'HH:MM')]);
end
scatter(x_source, y_source, 100, 'r^', 'filled', 'DisplayName', '源点');
xlabel('经度');
ylabel('纬度');
title(['目标日期有效反演事件观测点分布 (', datestr(target_date, 'yyyy-mm-dd'), ')']);
legend('Location', 'best');
grid on;
hold off;


%% ==================== 生成典型日排放 ====================
event_dates = floor(results.time);
idx_date = (event_dates == target_date);

if ~any(idx_date)
    error('指定日期 %s 不在有效反演结果中。', target_date_str);
end

if sum(idx_date) > 1
    Q_daily = mean(results.Q(idx_date));
    fprintf('日期 %s 有 %d 个反演事件，取平均 Q = %.2f 吨/小时\n', ...
        datestr(target_date, 'yyyy-mm-dd'), sum(idx_date), Q_daily);
else
    Q_daily = results.Q(idx_date);
    fprintf('日期 %s 只有 1 个反演事件，Q = %.2f 吨/小时\n', ...
        datestr(target_date, 'yyyy-mm-dd'), Q_daily);
end

if use_load_data
    scale = total_load / mean(total_load);
    Q_24h = Q_daily * scale;   % 1×24
else
    Q_24h = Q_daily * ones(1,24);
end

typical_days = struct();
typical_days.date = target_date;
typical_days.Q_daily = Q_daily;
typical_days.Q_24h = Q_24h;
typical_days.event_times = results.time;
typical_days.event_Q = results.Q;

if use_load_data
    typical_days.load_used = total_load;
end

save('typical_day_one.mat', 'typical_days');
fprintf('已保存日期 %s 的24小时序列\n', datestr(target_date, 'yyyy-mm-dd'));

%% ==================== 图4：选定典型日的 XCO2 沿轨分布图 ====================
target_idx = find(floor(results.time) == target_date, 1);

if isempty(target_idx)
    warning('选定日期 %s 没有对应的有效事件，无法绘制沿轨分布图', target_date_str);
else
    figure('Name', 'XCO2沿轨分布');
    x_vals = 1:length(event_xco2{target_idx});
    plot(x_vals, event_xco2{target_idx}, '-', 'Color', '#568bc1', ...
         'LineWidth', 1.2);
    
    xlabel('观测点序号 (沿轨方向)');
    ylabel('XCO₂ (ppm)');
    grid on;

    c_bg = min(event_xco2{target_idx});
    hold on;
    yline(c_bg, 'r--', 'LineWidth', 1.5, ...
        'DisplayName', sprintf('背景浓度 = %.1f ppm', c_bg));
    legend;
    hold off;
end

%% ==================== 图5：负荷曲线图 ====================
figure('Name', '典型日负荷曲线');
plot(0:23, load_e, 'b-', 'LineWidth', 1.5, 'DisplayName', '电负荷');
hold on;
plot(0:23, load_h, 'r-', 'LineWidth', 1.5, 'DisplayName', '热负荷');
plot(0:23, total_load, 'k--', 'LineWidth', 1.5, 'DisplayName', '总负荷');
xlabel('小时', 'FontSize', 14);
ylabel('负荷 (kW)', 'FontSize', 14);
legend('Location', 'best', 'FontSize', 14);
grid on;
xlim([-0.5 23.5]);

%% ==================== 图6：选定典型日24小时排放通量图 ====================
if exist('typical_days', 'var') && isfield(typical_days, 'Q_24h')
    figure('Name', '选定典型日排放通量');
    bar(0:23, typical_days.Q_24h, 'FaceColor', [0.2 0.6 0.9]);
    xlabel('小时', 'FontSize', 14);
    ylabel('排放通量 (吨/小时)', 'FontSize', 14);
    grid on;
    xlim([-0.5 23.5]);
else
    warning('未找到 typical_days 变量或 Q_24h 字段，请先生成选定典型日的24小时序列');
end

fprintf('所有图表绘制完成。\n');

%% ==================== 保存结果 ====================
save(outputFile, 'typical_days');
fprintf('结果已保存至：%s\n', outputFile);

fid = fopen('typical_days_info.txt', 'w');
fprintf(fid, '典型日排放通量信息\n');
fprintf(fid, '日期\t代表Q(吨/小时)\n');
fprintf(fid, '%s\t%.4f\n', datestr(target_date, 'yyyy-mm-dd'), Q_daily);
fclose(fid);
fprintf('文本信息已保存至 typical_days_info.txt\n');

%% ==================== 子函数：高斯烟羽反演 ====================
function Q = gaussian_plume_inversion_full(x_obs, y_obs, c_obs, x_src, y_src, met)
    if nargin < 6
        error('需要传入气象数据结构体 met');
    end

    ppm_to_kgm3 = 1.0e-6 * 44.01 / 28.97 * 1.2;

    deg2m_lat = 111320;
    deg2m_lon = 111320 * cosd(mean(y_obs));
    x_m = (x_obs - x_src) * deg2m_lon;
    y_m = (y_obs - y_src) * deg2m_lat;

    transport_dir = mod(met.wdir + 180, 360);
    theta = deg2rad(90 - transport_dir);

    x_rot =  x_m * cos(theta) + y_m * sin(theta);
    y_rot = -x_m * sin(theta) + y_m * cos(theta);

    downwind = x_rot > 0;
    if sum(downwind) < 2
        Q = NaN;
        return;
    end

    x_rot = x_rot(downwind);
    y_rot = y_rot(downwind);
    c_obs = c_obs(downwind);

    c_bg = prctile(c_obs, 10);
    delta_c = max(c_obs - c_bg, 0);

    [~, sigma_z_func] = get_briggs_coeff(met.stab_class, 'urban');
    sigma_z_temp = sigma_z_func(x_rot);

    plume_thickness = 2 * sigma_z_temp;
    plume_thickness = min(plume_thickness, met.pblh);
    plume_thickness(plume_thickness < 1) = 1;

    scale_factor = met.pblh ./ plume_thickness;
    scale_factor = min(scale_factor, 5.0);
    delta_c_ground = delta_c .* scale_factor;

    delta_c_kgm3 = delta_c_ground * ppm_to_kgm3;

    [sigma_y_func, sigma_z_func] = get_briggs_coeff(met.stab_class, 'urban');
    sigma_y = sigma_y_func(x_rot);
    sigma_z = sigma_z_func(x_rot);

    sigma_y(sigma_y < 1) = 1;
    sigma_z(sigma_z < 1) = 1;

    sigma_z = min(sigma_z, met.pblh / 2.15);

    denominator = exp(-y_rot.^2 ./ (2*sigma_y.^2));
    denominator(denominator < 1e-6) = 1e-6;

    Q_est = delta_c_kgm3 .* (2*pi*met.u.*sigma_y.*sigma_z) ./ denominator;

    Q_median = median(Q_est, 'omitnan');
    Q = Q_median * 3.6;
end

function [sigma_y_func, sigma_z_func] = get_briggs_coeff(stab_class, terrain) %#ok<INUSD>
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
            sigma_z_func = @(x) 0.08 * x .* (1 + 0.0015*x).^(-0.5);
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
                rad_class = 4; % 强辐射
            else
                rad_class = 3; % 较强辐射
            end
        elseif h >= 35
            if tcc <= 0.5
                rad_class = 3; % 较强辐射
            else
                rad_class = 2; % 中等辐射
            end
        else
            if tcc <= 0.5
                rad_class = 2; % 中等辐射
            else
                rad_class = 1; % 弱辐射
            end
        end
    end
    
    % 3. 根据辐射等级和风速确定稳定度 (Pasquill) 
    if rad_class == 0   % 夜间逻辑 (不变)
        if tcc >= 0.8
            stab = 'D'; % 多云夜晚，中性
        else % 少云夜晚
            if u10 <= 2
                stab = 'F';
            elseif u10 <= 3
                stab = 'E';
            else % u10 > 3
                stab = 'D';
            end
        end
    else % 白天逻辑
        % 统一规则：风速越大越趋向中性(D)，辐射越强越趋向不稳定(A)
        if u10 < 2
            if rad_class >= 3 % 辐射强或较强
                stab = 'A';
            elseif rad_class == 2 % 辐射中
                stab = 'B';
            else % rad_class == 1, 辐射弱
                stab = 'C';
            end
        elseif u10 >= 2 && u10 < 3
            if rad_class >= 4 % 辐射强
                stab = 'A';
            else % 辐射中或弱
                stab = 'B';
            end
        elseif u10 >= 3 && u10 < 5
            if rad_class >= 4 % 辐射强
                stab = 'B';
            else
                stab = 'C';
            end
        else % u10 >= 5 (强风速)
            stab = 'D'; % 强风下，机械湍流占主导，趋于中性
        end
    end
end

function h = solar_altitude(lat, lon, time_datenum)
    jd = time_datenum + 2415018.5;
    n = jd - 2451545.0;

    L = mod(280.460 + 0.9856474 * n, 360);
    g = mod(357.528 + 0.9856003 * n, 360);
    lambda = L + 1.915 * sind(g) + 0.020 * sind(2*g);
    epsilon = 23.439 - 0.0000004 * n;
    delta = asind(sind(epsilon) * sind(lambda));

    GMST = mod(280.46061837 + 360.98564736629 * n, 360);
    LST = GMST + lon;
    UT = (time_datenum - floor(time_datenum)) * 24;
    hour_angle = mod(LST - 15 * UT, 360);
    if hour_angle > 180
        hour_angle = hour_angle - 360;
    end

    h = asind(sind(lat) * sind(delta) + cosd(lat) * cosd(delta) * cosd(hour_angle));
end