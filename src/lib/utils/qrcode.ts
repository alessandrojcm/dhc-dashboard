import QRCode from 'qrcode';
import { PUBLIC_SITE_URL } from '$env/static/public';

export interface QRCodeOptions {
  margin?: number;
  width?: number;
  color?: {
    dark?: string;
    light?: string;
  };
}

/**
 * Generate QR code for workshop check-in
 */
export async function generateWorkshopQR(
  workshopId: string, 
  format: 'svg' | 'png' | 'jpeg' = 'svg',
  options: QRCodeOptions = {}
) {
  const checkinUrl = `${PUBLIC_SITE_URL}/workshop/checkin/${workshopId}`;
  
  const defaultOptions = {
    margin: 2,
    width: 200,
    color: {
      dark: '#000000',
      light: '#FFFFFF'
    },
    ...options
  };

  if (format === 'svg') {
    const qrCodeSvg = await QRCode.toString(checkinUrl, { 
      type: 'svg',
      ...defaultOptions
    });
    
    return {
      url: checkinUrl,
      data: qrCodeSvg,
      format: 'svg' as const
    };
  } else {
    const qrCodeDataUrl = await QRCode.toDataURL(checkinUrl, {
      type: format === 'png' ? 'image/png' : 'image/jpeg',
      ...defaultOptions
    });
    
    return {
      url: checkinUrl,
      data: qrCodeDataUrl,
      format: format as 'png' | 'jpeg'
    };
  }
}



/**
 * Generate QR code for any URL
 */
export async function generateQRCode(
  url: string,
  format: 'svg' | 'png' | 'jpeg' = 'svg',
  options: QRCodeOptions = {}
) {
  const defaultOptions = {
    margin: 2,
    width: 200,
    color: {
      dark: '#000000',
      light: '#FFFFFF'
    },
    ...options
  };

  if (format === 'svg') {
    const qrCodeSvg = await QRCode.toString(url, { 
      type: 'svg',
      ...defaultOptions
    });
    
    return {
      url,
      data: qrCodeSvg,
      format: 'svg' as const
    };
  } else {
    const qrCodeDataUrl = await QRCode.toDataURL(url, {
      type: format === 'png' ? 'image/png' : 'image/jpeg',
      ...defaultOptions
    });
    
    return {
      url,
      data: qrCodeDataUrl,
      format: format as 'png' | 'jpeg'
    };
  }
}