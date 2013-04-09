define([
        'lib/text!icons/point.svg',
        'lib/text!icons/polyline.svg',
        'lib/text!icons/cube.svg',
        'lib/text!icons/sphere.svg',
        'lib/text!icons/subtract.svg',
        'lib/text!icons/cog.svg',
        'lib/text!icons/tag.svg',
        'lib/text!icons/list.svg',
    ], 
    function(
        point, 
        polyline,
        cube,
        sphere,
        subtract,
        cog,
        tag,
        list) {

    return {
        point    : point, 
        polyline : polyline,
        cube     : cube,
        sphere   : sphere,
        subtract : subtract,
        cog      : cog,
        tag      : tag,
        list     : list,
    }

});