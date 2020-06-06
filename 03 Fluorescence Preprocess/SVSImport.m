% This script imports Fluorescence images in SVS format.
% This is similar to SP5Import but for SVS

%% Inputs

%Where to upload data
s3Dir = s3SubjectPath('01');

slideNumber = 1;

folderPath = '\\171.65.17.174\e\Caroline\OCT-Histology\';
flourescenceImagePath = [folderPath 'FM.svs'];
brightfieldImagePath = [folderPath 'BF.svs'];

% How deep below gel-tissue interface to aquire data
howDeepIsTissue_mm = 1.5;

% Resolution to save (upload to aws)
resToUpload = 0.7; % um per pixel, 20x

%% Jenkins
if exist('s3Dir_','var')
    s3Dir = s3Dir_;
    folderStructurePath = folderStructurePath_;
    angRotate = angRotate_;
end

%% Read StackConfig.json to make sure section naming is consistent with instructions
stackConfig = awsReadJSON([s3Dir '/Slides/StackConfig.json']);
sectionNames = stackConfig.sections.names;

% Sort out section names by slide
sectionNames = sectionNames(cellfun(@(x)contains(x,sprintf('Slide%02d',slideNumber)),sectionNames));

%% Get general information from SVS file

infoFM =imfinfo(flourescenceImagePath);
infoBF =imfinfo(brightfieldImagePath);

% Load low resolution FM, slide info etc
lowResSlideLevel = 4;
lowResSlideIm=rgb2gray(imread(flourescenceImagePath,'Index',lowResSlideLevel));
if length(infoFM) == 7
    slideInfoIm  =imread(flourescenceImagePath,'Index',6);
    wholeSlideLevel = 7; 
else
    slideInfoIm  =imread(flourescenceImagePath,'Index',5);
    wholeSlideLevel = 6; 
end
wholeSlideIm =imread(flourescenceImagePath,'Index',wholeSlideLevel);
wholeSlideIm = rgb2gray(wholeSlideIm);

if size(lowResSlideIm,1) > size(lowResSlideIm,2)
    isTranspose = true;
else
    isTranspose = false;
end

if isTranspose
    lowResSlideIm = transpose(lowResSlideIm);
    wholeSlideIm = transpose(wholeSlideIm);
end

% Compute pixel size, see: 
% http://www.fileformat.info/format/tiff/corion.htm
xResolution_umperpix = zeros(size(infoFM))*NaN;
yResolution_umperpix = zeros(size(infoFM))*NaN;
for i=1:length(xResolution_umperpix)
    switch(lower(infoFM(i).ResolutionUnit))
        case 'centimeter'
            xResolution_umperpix(i) = 10000/infoBF(i).XResolution;
            yResolution_umperpix(i) = 10000/infoBF(i).YResolution;
    end
end
resolution_umperpix = xResolution_umperpix;

% Which tiff stack level resulution to upload
[~,toUploadLevel] = min(abs(resolution_umperpix-resToUpload));

%% Make the main figure
%Make the main figure
figure(1);
subplot(3,3,1);
imshow(slideInfoIm);
subplot(3,3,[2 3]);
imshow(wholeSlideIm);
ax =  subplot(3,3,4:9);
imshow(lowResSlideIm);
s = size(lowResSlideIm); s = s(1:2);

%% Loop over sections, mark position of the lines
roixs = zeros(2,length(sectionNames));
roiys = roixs;
up_direction = [0;0]; %x,y components of up direction (from tissue to gel).
% Norm of up_direction
for si=1:length(sectionNames)
    figure(1);
    subplot(ax);
    title(sprintf('Please mark tissue-gel interface from first photobleach line to last.\n%s Press Space When Done',...
         strrep(sectionNames{si},'_',' ')));
    if (~exist('roi','var'))
        h=imline(ax,s(2)*[1/3 2/3],s(1)*[1/3 2/3]);
    else
        %Use previuse ROI size
        h=imline(ax,roi(:,1)+s(2)*[0.1;0.1],roi(:,2));
    end
    while(waitforbuttonpress()==0) %Wait for button press
    end
    
    roi=getPosition(h);
    if (isTranspose)
        roiys(:,si) = roi(:,1);
        roixs(:,si) = roi(:,2);
    else
        roixs(:,si) = roi(:,1);
        roiys(:,si) = roi(:,2);
    end
  
    delete(h);
    
    if (si==1)
        title('Please mark the top of the gel. Press spacebar to continue.');
        h=imline(ax,roi(:,1)+s(2)*[0.1;0.1],roi(:,2));
        while(waitforbuttonpress()==0) %Wait for button press
        end
        up=mean(getPosition(h));
        delete(h);
        
        % Compute vector from a line to a point, using these equations:
        % https://math.stackexchange.com/questions/1398634/finding-a-perpendicular-vector-from-a-line-to-a-point
        u1 = (roi(2,:)-roi(1,:))';
        u0 = roi(1,:)';
        P = up';
        Pprime = dot(P-u0,u1)/norm(u1)^2*u1+u0;
        
        up_direction = P-Pprime;
        if (isTranspose)
            up_direction = flipud(up_direction);
        end
        
        if true
            hold on;
            plot(Pprime(1),Pprime(2),'o')
            plot(P(1),P(2),'o')
            plot(u0(1)+[0 u1(1)],u0(2)+[0 u1(2)]); 
            hold off;
        end
    end
end

%% Loop over sections, capture & Save
howDeepIsTissue_px = howDeepIsTissue_mm*1000 / resolution_umperpix(lowResSlideLevel); % How deep is the tissue in pixels?
down_direction = -up_direction/norm(up_direction)*howDeepIsTissue_px;
for si=1:length(sectionNames)
    
    % Figure out section dimensions to save. Start by computing a rectangle
    % that captures the section
    x = [ ...
            roixs(1,si)+down_direction(1), ...
            roixs(2,si)+down_direction(1), ...
            roixs(2,si)+up_direction(1), ...
            roixs(1,si)+up_direction(1) ...
        ];
    y = [ ...
            roiys(1,si)+down_direction(2), ...
            roiys(2,si)+down_direction(2), ...
            roiys(2,si)+up_direction(2), ...
            roiys(1,si)+up_direction(2) ...
        ];
    if true
        hold on;
        if (isTranspose)
            plot(y,x);
        else
            plot(x,y);
        end
        hold off;
    end
    
    % Get the corresponding area from the file
    r = [min(y) max(y)];
    c = [min(x) max(x)];
    Rows=round(r*infoBF(toUploadLevel).Height/infoBF(lowResSlideLevel).Height);
    Cols=round(c*infoBF(toUploadLevel).Width /infoBF(lowResSlideLevel).Width);
    
    rot_deg = asin(up_direction(2)/norm(up_direction))*180/pi + 90; % Rotation angle
    
    % Get FM image
    im = rgb2gray(imread(flourescenceImagePath,'Index',toUploadLevel,'PixelRegion',{Rows,Cols}));
    im = imrotate(im,rot_deg,'bilinear','crop');
    photobleachedLinesImagePath = 'FM_PhotobleachedLinesImage.tif';
    imwrite(im,photobleachedLinesImagePath);
    
    % Get bright field image
    im = rgb2gray(imread(brightfieldImagePath,'Index',toUploadLevel,'PixelRegion',{Rows,Cols}));
    im = imrotate(im,rot_deg,'bilinear','crop');
    brightFieldImagePath = 'FM_BrightfieldImage.tif';
    imwrite(im,brightFieldImagePath);
    
    % Set up the json
    json = [];
    json.version = 1.2;
    json.FM.pixelSize_um = resolution_umperpix(toUploadLevel);
    json.FM.imagedAt = datestr(infoFM(toUploadLevel).FileModDate);
    json.FM.imageSize_pix = size(im);
    json.photobleachedLinesImagePath = photobleachedLinesImagePath;
    json.brightFieldImagePath = brightFieldImagePath;
    
    % Upload
    outputFolder = [s3Dir '/Slides/' sectionNames '/'];
    awsWriteJSON(json,[outputFolder '/SlideConfig.json']);
    awsCopyFileFolder(json.photobleachedLinesImagePath,outputFolder);
    awsCopyFileFolder(json.brightFieldImagePath,outputFolder);
end

close;