#include <mbgl/text/local_glyph_rasterizer.hpp>
#include <mbgl/util/i18n.hpp>
#include <mbgl/util/platform.hpp>
#include <mbgl/util/constants.hpp>

#include <unordered_map>
#include <iterator>

#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>

#import "CFHandle.hpp"

namespace mbgl {

/*
    Darwin implementation of LocalGlyphRasterizer:
     Draws CJK glyphs using locally available fonts.
 
    Mirrors GL JS implementation in that:
     - Only CJK glyphs are drawn locally (because we can guess their metrics effectively)
        * Render size/metrics determined experimentally by rendering a few different fonts
     - Configuration is done at map creation time by setting a "font family"
        * JS uses a CSS font-family, this uses kCTFontFamilyNameAttribute which has
          somewhat different behavior.
 
    Further improvements are possible:
     - GL JS heuristically determines a font weight based on the strings included in
        the FontStack. Android follows a simpler heuristic that just picks up the
        "Bold" property from the FontStack. Although both should be possible with CoreText,
        our initial implementation couldn't reliably control the font-weight, so we're
        skipping that functionality on darwin.
        (See commit history for attempted implementation)
     - If we could reliably extract glyph metrics, we wouldn't be limited to CJK glyphs
     - We could push the font configuration down to individual style layers, which would
        allow any current style to be reproducible using local fonts.
     - Instead of just exposing "font family" as a configuration, we could expose a richer
        CTFontDescriptor configuration option (although we'd have to override font size to
        make sure it stayed at 24pt).
     - Because Apple exposes glyph paths via `CTFontCreatePathForGlyph` we could potentially
        render directly to SDF instead of going through TinySDF -- although it's not clear
        how much of an improvement it would be.
*/

using CGColorSpaceHandle = CFHandle<CGColorSpaceRef, CGColorSpaceRef, CGColorSpaceRelease>;
using CGContextHandle = CFHandle<CGContextRef, CGContextRef, CGContextRelease>;
using CFStringRefHandle = CFHandle<CFStringRef, CFTypeRef, CFRelease>;
using CFAttributedStringRefHandle = CFHandle<CFAttributedStringRef, CFTypeRef, CFRelease>;
using CFMutableArrayRefHandle = CFHandle<CFMutableArrayRef, CFTypeRef, CFRelease>;
using CFDictionaryRefHandle = CFHandle<CFDictionaryRef, CFTypeRef, CFRelease>;
using CTFontRefHandle = CFHandle<CTFontRef, CFTypeRef, CFRelease>;
using CTFontDescriptorRefHandle = CFHandle<CTFontDescriptorRef, CFTypeRef, CFRelease>;
using CTLineRefHandle = CFHandle<CTLineRef, CFTypeRef, CFRelease>;

CTFontDescriptorRef createFontDescriptor(const FontStack& fontStack, NSArray<NSString *>* fallbackFontNames, bool isVertical);

class LocalGlyphRasterizer::Impl {
public:
    Impl(const optional<std::string> fontFamily_)
    {
        fallbackFontNames = [[NSUserDefaults standardUserDefaults] stringArrayForKey:@"MGLIdeographicFontFamilyName"];
        if (fontFamily_) {
            fallbackFontNames = [fallbackFontNames ?: @[] arrayByAddingObjectsFromArray:[@(fontFamily_->c_str()) componentsSeparatedByString:@"\n"]];
        }
    }
    
    ~Impl() {
    }
    
    bool isEnabled() { return fallbackFontNames; }
    
private:
    NSArray<NSString *> *fallbackFontNames;
};

LocalGlyphRasterizer::LocalGlyphRasterizer(const optional<std::string>& fontFamily)
    : impl(std::make_unique<Impl>(fontFamily))
{}

LocalGlyphRasterizer::~LocalGlyphRasterizer()
{}

bool LocalGlyphRasterizer::canRasterizeGlyph(const FontStack&, GlyphID) {
    return impl->isEnabled();
}

PremultipliedImage drawGlyphBitmap(GlyphID glyphID, CTFontRef font, Size size) {
    CGGlyph glyphs[] = { glyphID };
    PremultipliedImage rgbaBitmap(size);
    
    CGColorSpaceHandle colorSpace(CGColorSpaceCreateDeviceRGB());
    if (!colorSpace) {
        throw std::runtime_error("CGColorSpaceCreateDeviceRGB failed");
    }
    
    constexpr const size_t bitsPerComponent = 8;
    constexpr const size_t bytesPerPixel = 4;
    const size_t bytesPerRow = bytesPerPixel * size.width;

    CGContextHandle context(CGBitmapContextCreate(
        rgbaBitmap.data.get(),
        size.width,
        size.height,
        bitsPerComponent,
        bytesPerRow,
        *colorSpace,
        kCGBitmapByteOrderDefault | kCGImageAlphaPremultipliedLast));
    if (!context) {
        throw std::runtime_error("CGBitmapContextCreate failed");
    }
    
    CGPoint positions[1];
    positions[0] = CGPointMake(0.0, 5.0);
    CTFontDrawGlyphs(font, glyphs, positions, 1, *context);
    
    return rgbaBitmap;
}

Glyph LocalGlyphRasterizer::rasterizeGlyph(const FontStack& fontStack, GlyphID glyphID) {
    Glyph manufacturedGlyph;
    CFStringRef fontName = (__bridge CFStringRef)@(fontStack.front().c_str());
    CTFontRefHandle font(CTFontCreateWithName(fontName, 0.0, NULL));
    
    manufacturedGlyph.id = glyphID;

    // TODO: Plumb through vertical text.
    CTFontOrientation orientation = kCTFontOrientationHorizontal;
    
    CGRect boundingRects[1];
    CGGlyph glyphs[] = { glyphID };
    CGRect boundingRect = CTFontGetBoundingRectsForGlyphs(*font, orientation, glyphs, boundingRects, 1);
    if (CGRectIsNull(boundingRect)) {
        throw std::runtime_error("CTFontGetBoundingRectsForGlyphs failed");
    }
    manufacturedGlyph.metrics.left = 3;
    manufacturedGlyph.metrics.top = -1;
    manufacturedGlyph.metrics.width = 35;
    manufacturedGlyph.metrics.height = 35;
    
    CGSize advances[1];
    CTFontGetAdvancesForGlyphs(*font, orientation, glyphs, advances, 1);
    manufacturedGlyph.metrics.advance = 24;
    
    Size size(manufacturedGlyph.metrics.width, manufacturedGlyph.metrics.height);
    PremultipliedImage rgbaBitmap = drawGlyphBitmap(glyphID, *font, size);
   
    // Copy alpha values from RGBA bitmap into the AlphaImage output
    manufacturedGlyph.bitmap = AlphaImage(size);
    for (uint32_t i = 0; i < size.width * size.height; i++) {
        manufacturedGlyph.bitmap.data[i] = rgbaBitmap.data[4 * i + 3];
    }

    return manufacturedGlyph;
}

CTFontDescriptorRef createFontDescriptor(const FontStack& fontStack, NSArray<NSString *>* fallbackFontNames, bool isVertical) {
    NSMutableArray *fontNames = [NSMutableArray arrayWithCapacity:fontStack.size() + fallbackFontNames.count];
    for (auto& fontName : fontStack) {
        if (fontName != util::LAST_RESORT_ALPHABETIC_FONT && fontName != util::LAST_RESORT_PAN_UNICODE_FONT) {
            [fontNames addObject:@(fontName.c_str())];
        }
    }
    [fontNames addObjectsFromArray:fallbackFontNames];
    
    CFMutableArrayRefHandle fontDescriptors(CFArrayCreateMutable(kCFAllocatorDefault, fontNames.count, &kCFTypeArrayCallBacks));
    for (NSString *name in fontNames) {
        NSDictionary *fontAttributes = @{
            (NSString *)kCTFontSizeAttribute: @(util::ONE_EM),
            (NSString *)kCTFontNameAttribute: name,
            (NSString *)kCTFontDisplayNameAttribute: name,
            (NSString *)kCTFontFamilyNameAttribute: name,
        };
        
        CTFontDescriptorRefHandle descriptor(CTFontDescriptorCreateWithAttributes((CFDictionaryRef)fontAttributes));
        CFArrayAppendValue(*fontDescriptors, *descriptor);
    }
    
    CTFontOrientation orientation = isVertical ? kCTFontOrientationVertical : kCTFontOrientationHorizontal;

    CFStringRef keys[] = { kCTFontSizeAttribute,                  kCTFontCascadeListAttribute, kCTFontOrientationAttribute };
    CFTypeRef values[] = { (__bridge CFNumberRef)@(util::ONE_EM), *fontDescriptors,            (__bridge CFNumberRef)@(orientation) };

    CFDictionaryRefHandle attributes(
        CFDictionaryCreate(kCFAllocatorDefault, (const void**)&keys,
            (const void**)&values, sizeof(keys) / sizeof(keys[0]),
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks));
    if (CFArrayGetCount(*fontDescriptors)) {
        CTFontDescriptorRef firstDescriptor = (CTFontDescriptorRef)CFArrayGetValueAtIndex(*fontDescriptors, 0);
        return CTFontDescriptorCreateCopyWithAttributes(firstDescriptor, *attributes);
    } else {
        return CTFontDescriptorCreateWithAttributes(*attributes);
    }
}

GlyphDependencies getGlyphDependencies(const FontStack& fontStack, const std::string& text, bool isVertical) {
    // TODO: Implement global fallback fonts.
    CTFontDescriptorRefHandle descriptor(createFontDescriptor(fontStack, @[], isVertical));
    CTFontRefHandle font(CTFontCreateWithFontDescriptor(*descriptor, 0.0, NULL));

    CFStringRef keys[] = { kCTFontAttributeName };
    CFTypeRef values[] = { *font };

    CFDictionaryRefHandle attributes(
        CFDictionaryCreate(kCFAllocatorDefault, (const void**)&keys,
            (const void**)&values, sizeof(keys) / sizeof(keys[0]),
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks));

    CFStringRef string = (__bridge CFStringRef)@(text.c_str());
    CFAttributedStringRefHandle attrString(CFAttributedStringCreate(kCFAllocatorDefault, string, *attributes));
    CTLineRefHandle line(CTLineCreateWithAttributedString(*attrString));
    
    CFArrayRef glyphRuns = CTLineGetGlyphRuns(*line);
    GlyphDependencies dependencies;
    for (CFIndex i = 0; i < CFArrayGetCount(glyphRuns); i++) {
        CTRunRef glyphRun = (CTRunRef)CFArrayGetValueAtIndex(glyphRuns, 0);
        CFRange wholeRunRange = CFRangeMake(0, CTRunGetGlyphCount(glyphRun));
        
        CTFontRef glyphFont = (CTFontRef)CFDictionaryGetValue(CTRunGetAttributes(glyphRun), kCTFontAttributeName);
        CFStringRefHandle glyphFontName(CTFontCopyName(glyphFont, kCTFontPostScriptNameKey));
        FontStack glyphFontStack = {{ [(__bridge NSString *)*glyphFontName UTF8String] }};
        
        // Use CTRunGetGlyphsPtr() if available.
        CGGlyph glyphs[wholeRunRange.length];
        CTRunGetGlyphs(glyphRun, wholeRunRange, glyphs);
        
        GlyphIDs& glyphIDs = dependencies[glyphFontStack];
        glyphIDs.insert(glyphs, glyphs + wholeRunRange.length);
    }
    return dependencies;
}

} // namespace mbgl
