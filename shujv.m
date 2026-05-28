clear; clc;

%% 1. 读取你已有的典型日数据
load('typical_day_one.mat');   % 包含 typical_days 结构体

loadFile = 'carbon+DR数据.xlsx';
load_e = xlsread(loadFile, 1, 'A2:X2');   % 24小时电负荷
load_h = xlsread(loadFile, 1, 'A3:X3');   % 24小时热负荷
price_e = xlsread(loadFile, 1, 'A4:X4');
pv_avail = xlsread(loadFile, 1, 'A5:X5');
Q_24h = typical_days.Q_24h(:)';   % 转成行向量



%% 3. 检查长度
if length(load_e) ~= 24 || length(load_h) ~= 24 || length(Q_24h) ~= 24 || length(price_e) ~= 24 || length(pv_avail) ~= 24
    error('输入数据长度不是24，请检查！');
end

%% 4. 保存为调度模型输入文件
save('dispatch_input.mat', 'load_e', 'load_h', 'Q_24h', 'price_e','pv_avail');

fprintf('调度模型输入文件 dispatch_input.mat 已生成。\n');